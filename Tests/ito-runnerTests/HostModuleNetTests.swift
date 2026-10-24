import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

struct MockNetModule: NetModule {
    func fetch(request: NetRequest) async throws -> NetResponse {
        // Assert we got what we expected
        #expect(request.url == "https://example.com")
        #expect(request.method == "GET")

        return NetResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: [1, 2, 3, 4]
        )
    }
}

@Suite("Host Modules - NetModule")
struct HostModuleNetTests {

    @Test("NetModule Fetch FFI Bridge")
    func testNetFetchFFI() async throws {
        // 1. Create a minimal WASM module using WAT that:
        // - Imports `ito:core/net/fetch`
        // - Exports linear memory
        // - Exports `alloc`
        // - Exports a test function to trigger the fetch
        let watSrc = """
            (module
                (import "ito:core/net" "fetch" (func $fetch (param i32 i32) (result i32)))
                (import "ito:core/net" "fetch_read" (func $fetch_read (param i32)))
                (memory (export "memory") 1)

                (func $alloc (export "alloc") (param i32) (result i32)
                    ;; Just return a fixed offset like 1024 for testing allocation
                    i32.const 1024
                )

                (func (export "trigger_fetch") (param $ptr i32) (param $len i32) (result i64)
                    (local $response_len i32)
                    (local $response_ptr i32)

                    local.get $ptr
                    local.get $len
                    call $fetch
                    local.set $response_len

                    local.get $response_len
                    call $alloc
                    local.set $response_ptr

                    local.get $response_ptr
                    call $fetch_read

                    local.get $response_ptr
                    i64.extend_i32_u
                    i64.const 32
                    i64.shl
                    local.get $response_len
                    i64.extend_i32_u
                    i64.or
                )
            )
            """

        let wasmBytes = try wat2wasm(watSrc)

        // 2. Setup runner and inject the mock module
        let runner = ItoRunner()
        let bridge = WasmBridge(runner: runner)
        bridge.netModule = MockNetModule()

        let engine = Engine()
        let store = Store(engine: engine)
        let module = try parseWasm(bytes: [UInt8](wasmBytes))

        let imports = bridge.buildImports(store: store)
        let instance = try module.instantiate(store: store, imports: imports)

        // 3. Prepare the request
        let request = NetRequest(
            url: "https://example.com",
            method: "GET",
            headers: [:],
            body: nil
        )
        let requestBytes = try ItoPostcardEncoder().encode(request)

        // 4. Manually write the request into the Wasm memory at offset 0
        guard let memoryExport = instance.exports["memory"],
            case .memory(let memory) = memoryExport
        else {
            Issue.record("Missing memory export")
            return
        }

        memory.withUnsafeMutableBufferPointer(offset: 0, count: requestBytes.count) { buffer in
            requestBytes.withUnsafeBytes { src in
                buffer.copyMemory(from: UnsafeRawBufferPointer(src))
            }
        }

        // 5. Trigger the FFI by calling the exported Wasm function
        guard let trigger = instance.exports[function: "trigger_fetch"] else {
            Issue.record("Missing trigger_fetch export")
            return
        }

        let result = try trigger([.i32(0), .i32(UInt32(requestBytes.count))])

        // 6. Decode the returned packed pointer & length
        guard result.count == 1, case .i64(let packed) = result[0] else {
            Issue.record("Invalid return type from trigger")
            return
        }

        let responsePtr = UInt32(packed >> 32)
        let responseLen = UInt32(packed & 0xFFFF_FFFF)

        #expect(responsePtr == 1024, "Mock alloc didn't return 1024")

        // 7. Read the response bytes straight from Wasm memory at `responsePtr`
        let responseBytes = memory.withUnsafeMutableBufferPointer(
            offset: UInt(responsePtr), count: Int(responseLen)
        ) { buffer in
            Array(UnsafeRawBufferPointer(buffer))
        }

        let response = try ItoPostcardDecoder().decode(NetResponse.self, from: responseBytes)

        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.body == [1, 2, 3, 4])
    }
}

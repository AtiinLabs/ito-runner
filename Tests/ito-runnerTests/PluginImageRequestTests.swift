import Foundation
import Testing
import WAT
import WasmKit
@testable import ito_runner

@Suite("Native plugin image requests")
struct PluginImageRequestTests {
    private func runner(exports: String) async throws -> ItoRunner {
        let wasm = try wat2wasm("""
            (module
              (import "ito:core/std" "print" (func $print (param i32 i32)))
              (memory (export "memory") 1)
              ;; Rust postcard PluginImageRequest { url, Some({"K":"V"}) }
              (data (i32.const 64) "\\0ahttp://x/p\\01\\01\\01K\\01V")
              (data (i32.const 128) "\\01\\08http://x")
              (data (i32.const 256) "Error in get_image_request: Refused image")
              (data (i32.const 320) "Error in get_image_request: Unsupported operation")
              (global $deallocs (mut i32) (i32.const 0))
              (func (export "alloc") (param i32) (result i32) i32.const 1024)
              (func (export "dealloc") (param i32 i32)
                global.get $deallocs i32.const 1 i32.add global.set $deallocs)
              (func (export "dealloc_count") (result i32) global.get $deallocs)
              \(exports)
            )
            """)
        let runner = ItoRunner()
        await runner.setStdModule(DefaultStdModule())
        try await runner.loadPlugin(fromBytes: wasm)
        return runner
    }

    @Test func olderPluginsLeaveNativeResolutionUnsupported() async throws {
        let runner = try await runner(exports: "")
        #expect(try await runner.getImageRequest("api/v1/cover") == nil)
        #expect(try await runner.getImageOrigins() == nil)
    }

    @Test func configuredRequestsDecodeAndBothArgumentAndResultBuffersAreFreed() async throws {
        let runner = try await runner(exports: """
            (func (export "get_image_request") (param i32 i32) (result i64)
              i64.const \((UInt64(64) << 32) | 17))
            (func (export "get_image_origins") (result i64)
              i64.const \((UInt64(128) << 32) | 10))
            """)
        #expect(try await runner.getImageRequest("api/v1/cover") == PluginImageRequest(url: "http://x/p", headers: ["K": "V"]))
        #expect(try await runner.getImageOrigins() == ["http://x"])
        #expect(try await runner.executeExport("dealloc_count") == [.i32(3)])
    }

    @Test func explicitRefusalsAreNotTreatedAsUnsupported() async throws {
        let runner = try await runner(exports: """
            (func (export "get_image_request") (param i32 i32) (result i64)
              i32.const 256 i32.const 41 call $print i64.const 0)
            """)
        await #expect(throws: ItoError.pluginFailed(function: "get_image_request", reason: "Refused image")) {
            try await runner.getImageRequest("api/v1/refused")
        }
        #expect(try await runner.executeExport("dealloc_count") == [.i32(1)])
    }

    @Test func aProviderCanDeclineTheNativePathForAnImageItTransforms() async throws {
        let runner = try await runner(exports: """
            (func (export "get_image_request") (param i32 i32) (result i64)
              i32.const 320 i32.const 49 call $print i64.const 0)
            (func (export "get_image_origins") (result i64) i64.const 0)
            """)
        #expect(try await runner.getImageRequest("transformed") == nil)
        #expect(try await runner.getImageOrigins() == nil)
    }

    @Test func requestsWithoutHeadersAndWithEmptyHeadersRemainDistinct() throws {
        var bytes: [UInt8] = [10] + Array("http://x/p".utf8) + [0]
        #expect(try ItoPostcardDecoder().decode(PluginImageRequest.self, from: bytes).headers == nil)
        bytes[bytes.count - 1] = 1
        bytes.append(0)
        #expect(try ItoPostcardDecoder().decode(PluginImageRequest.self, from: bytes).headers == [:])
    }
}

import OSLog
import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

// Mock Modules
final class MockJsModule: JsModule, Sendable {
    func evaluate(script: String) throws -> String {
        if script == "return 1 + 1;" {
            return "2"
        }
        return "error"
    }
}

final class MockStdModule: StdModule, Sendable {
    func print(message: String) {
        // Assertions are tricky without shared state, but we can verify it doesn't crash
    }
}

final class MockDefaultsModule: DefaultsModule, Sendable {
    // using a non-isolated locked state or just mocking isolated behavior.
    // For test simplicity, we just return fixed values
    func set(key: String, value: String) {}
    func get(key: String) -> String? {
        if key == "test_key" {
            return "test_val"
        }
        return nil
    }
    func remove(key: String) {}
}

@Suite("Host Modules - Misc")
struct HostModuleMiscTests {

    @Test("JsModule Evaluate FFI Bridge")
    func testJsEvaluateFFI() async throws {
        let wat = """
            (module
                (import "ito:core/js" "evaluate" (func $js_eval (param i32 i32) (result i64)))
                (memory (export "memory") 1)

                ;; Data string at offset 16: "return 1 + 1;" -> 13 bytes
                (data (i32.const 16) "return 1 + 1;")

                (func (export "alloc") (param i32) (result i32)
                    (i32.const 1024)
                )

                (func (export "test_eval") (result i64)
                    (call $js_eval (i32.const 16) (i32.const 13))
                )
            )
            """

        let wasmBytes = try wat2wasm(wat)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("testJsEval.wasm")
        try Data(wasmBytes).write(to: file)

        let runner = ItoRunner()
        await runner.setJsModule(MockJsModule())

        try await runner.loadPlugin(from: file)

        let results = try await runner.executeExport("test_eval", args: [])

        guard let resultVal = results.first, case .i64(let packed) = resultVal else {
            Issue.record("Expected i64 result from test_eval")
            return
        }

        let responseLen = packed & 0xFFFF_FFFF
        let responsePtr = packed >> 32

        let responseBytes = try await runner.readMemory(
            offset: Int(responsePtr), length: Int(responseLen))

        let resultString = try runner.postcardDecoder.decode(String.self, from: responseBytes)
        #expect(resultString == "2")
    }

    @Test("DefaultsModule Get FFI Bridge")
    func testDefaultsGetFFI() async throws {
        let wat = """
            (module
                (import "ito:core/defaults" "get" (func $def_get (param i32 i32) (result i64)))
                (memory (export "memory") 1)

                ;; Data string at offset 16: "test_key" -> 8 bytes
                (data (i32.const 16) "test_key")

                (func (export "alloc") (param i32) (result i32)
                    (i32.const 1024)
                )

                (func (export "test_get") (result i64)
                    (call $def_get (i32.const 16) (i32.const 8))
                )
            )
            """

        let wasmBytes = try wat2wasm(wat)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("testDefGet.wasm")
        try Data(wasmBytes).write(to: file)

        let runner = ItoRunner()
        await runner.setDefaultsModule(MockDefaultsModule())
        try await runner.loadPlugin(from: file)

        let results = try await runner.executeExport("test_get", args: [])

        guard let resultVal = results.first, case .i64(let packed) = resultVal else {
            Issue.record("Expected i64 result from test_get")
            return
        }

        let responseLen = packed & 0xFFFF_FFFF
        let responsePtr = packed >> 32

        let responseBytes = try await runner.readMemory(
            offset: Int(responsePtr), length: Int(responseLen))

        let resultString = try runner.postcardDecoder.decode(String?.self, from: responseBytes)
        #expect(resultString == "test_val")
    }
}

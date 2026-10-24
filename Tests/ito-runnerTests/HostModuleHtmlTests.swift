import OSLog
import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

// A mock HTML module for testing
final class MockHtmlModule: HtmlModule, Sendable {
    func parse(html: String) throws -> UInt32 {
        if html == "<html><body>Hello</body></html>" {
            return 42
        }
        return 0
    }

    func select(elementId: UInt32, selector: String) throws -> [UInt32] {
        if elementId == 42 && selector == "body" {
            return [43, 44]
        }
        return []
    }

    func text(elementId: UInt32) throws -> String {
        if elementId == 43 {
            return "Hello"
        }
        return ""
    }

    func ownText(elementId: UInt32) throws -> String {
        return ""
    }

    func html(elementId: UInt32) throws -> String {
        return ""
    }

    func outerHtml(elementId: UInt32) throws -> String {
        return ""
    }

    func attr(elementId: UInt32, name: String) throws -> String? {
        if elementId == 44 && name == "class" {
            return "greeting"
        }
        return nil
    }

    func free(elementId: UInt32) {
        // no-op
    }

    func clear() {
        // no-op
    }
}

@Suite("Host Modules - HtmlModule")
struct HostModuleHtmlTests {

    @Test("HtmlModule Parse FFI Bridge")
    func testHtmlParseFFI() async throws {
        // 1. Create a dummy test Wasm module in WAT that invokes `ito:core/html/parse`
        let wat = """
            (module
                (import "ito:core/html" "parse" (func $html_parse (param i32 i32) (result i32)))
                (memory (export "memory") 1)

                ;; Data string at offset 16: "<html><body>Hello</body></html>" -> 31 bytes
                (data (i32.const 16) "<html><body>Hello</body></html>")

                ;; Dummy alloc function, unused in parse since it returns i32
                (func (export "alloc") (param i32) (result i32)
                    (i32.const 1024)
                )

                (func (export "test_parse") (result i32)
                    (call $html_parse (i32.const 16) (i32.const 31))
                )
            )
            """

        let wasmBytes = try wat2wasm(wat)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "testHtmlParse.wasm")
        try Data(wasmBytes).write(to: file)

        let runner = ItoRunner()
        await runner.setHtmlModule(MockHtmlModule())

        try await runner.loadPlugin(from: file)

        // 5. Invoke the `test_parse` exported function from Wasm
        let results = try await runner.executeExport("test_parse", args: [])

        // 6. Verify result
        guard let resultVal = results.first, case .i32(let elementId) = resultVal else {
            Issue.record("Expected i32 result from test_parse")
            return
        }

        #expect(elementId == 42)
    }

    @Test("HtmlModule Select FFI Bridge")
    func testHtmlSelectFFI() async throws {
        let wat = """
            (module
                (import "ito:core/html" "select" (func $html_select (param i32 i32 i32) (result i64)))
                (memory (export "memory") 1)

                ;; Data string at offset 16: "body" -> 4 bytes
                (data (i32.const 16) "body")

                (func (export "alloc") (param i32) (result i32)
                    (i32.const 1024)
                )

                (func (export "test_select") (result i64)
                    ;; Call with elementId = 42, ptr = 16, len = 4
                    (call $html_select (i32.const 42) (i32.const 16) (i32.const 4))
                )
            )
            """

        let wasmBytes = try wat2wasm(wat)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "testHtmlSelect.wasm")
        try Data(wasmBytes).write(to: file)
        let runner = ItoRunner()
        await runner.setHtmlModule(MockHtmlModule())

        try await runner.loadPlugin(from: file)

        let results = try await runner.executeExport("test_select", args: [])

        guard let resultVal = results.first, case .i64(let packed) = resultVal else {
            Issue.record("Expected i64 result from test_select")
            return
        }

        let responseLen = packed & 0xFFFF_FFFF
        let responsePtr = packed >> 32

        // Read response bytes
        let responseBytes = try await runner.readMemory(
            offset: Int(responsePtr), length: Int(responseLen))

        RunnerLogger.core.debug("responseBytes length: \(responseBytes.count)")
        RunnerLogger.core.debug("responseBytes: \(responseBytes)")

        let elements = try ItoPostcardDecoder().decode([Int32].self, from: responseBytes)
        #expect(elements == [43, 44])
    }
}

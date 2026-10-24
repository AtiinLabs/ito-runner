import Foundation
import Testing
import WAT
import WasmKit
@testable import ito_runner

@Suite("Optional settings diagnostics")
struct SettingsActionTests {
    enum Operation: CaseIterable, Sendable {
        case actions, run, validation

        var export: String {
            switch self {
            case .actions: "get_settings_actions"
            case .run: "run_settings_action"
            case .validation: "validate_settings"
            }
        }

        var parameters: String { self == .run ? "(param $id i32) (param $length i32)" : "" }

        func invoke(_ runner: ItoRunner) async throws -> Bool {
            switch self {
            case .actions: return try await runner.getSettingsActions() != nil
            case .run: return try await runner.runSettingsAction("検査") != nil
            case .validation: return try await runner.validateSettings() != nil
            }
        }
    }

    private func module(
        _ operation: Operation, payload: [UInt8] = [0], body: String? = nil,
        failure: PluginErrorCategory? = nil
    ) throws -> [UInt8] {
        let encoded = payload.map { String(format: "\\%02x", $0) }.joined()
        var failureExports = ""
        if let failure {
            let report = try ItoPostcardEncoder().encode(
                PluginErrorPayload(category: failure, message: "Unsupported operation")
            )
            let data = report.map { String(format: "\\%02x", $0) }.joined()
            failureExports = """
                (data (i32.const 256) "\(data)")
                (func (export "ito_error_version") (result i32) i32.const 2)
                (func (export "ito_last_error") (result i64)
                    i64.const \((UInt64(256) << 32) | UInt64(report.count)))
                """
        }
        return try wat2wasm("""
            (module
                (memory (export "memory") 1)
                (global $frees (mut i32) (i32.const 0))
                (func (export "alloc") (param i32) (result i32) i32.const 1024)
                (func (export "dealloc") (param i32 i32)
                    global.get $frees i32.const 1 i32.add global.set $frees)
                (func (export "free_count") (result i32) global.get $frees)
                (data (i32.const 64) "\(encoded)")
                \(failureExports)
                (func (export "\(operation.export)") \(operation.parameters) (result i64)
                    \(body ?? "i64.const \((UInt64(64) << 32) | UInt64(payload.count))"))
            )
            """)
    }

    @Test func missingExportsLeaveLegacyPluginsUsable() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wat2wasm("(module (memory (export \"memory\") 1))"))
        #expect(try await runner.getSettingsActions() == nil)
        #expect(try await runner.runSettingsAction("probe") == nil)
        #expect(try await runner.validateSettings() == nil)
    }

    @Test func payloadsDecodeTheSDKWireFormat() async throws {
        let runner = ItoRunner()
        // Independent Rust postcard fixtures, not bytes encoded from the Swift models under test.
        try await runner.loadPlugin(fromBytes: module(.actions, payload: Array("\u{01}\u{05}probe\u{04}Test\u{01}\u{02}Hi".utf8)))
        #expect(try await runner.getSettingsActions() == [SettingsAction(id: "probe", title: "Test", summary: "Hi")])
        try await runner.loadPlugin(fromBytes: module(.validation, payload: Array("\u{02}\u{03}url\u{07}Missing\u{00}\u{05}Setup".utf8)))
        #expect(try await runner.validateSettings() == [
            SettingIssue(key: "url", message: "Missing"), SettingIssue(key: "", message: "Setup")
        ])
    }

    @Test func unicodeActionIDReachesPluginAndBothBuffersAreFreed() async throws {
        let runner = ItoRunner()
        // Check UTF-8 byte length and its first byte in WASM, not by echoing an argument in a fake.
        let body = """
            local.get $length i32.const 6 i32.ne if unreachable end
            local.get $id i32.load8_u i32.const 230 i32.ne if unreachable end
            i64.const \((UInt64(64) << 32) | 7)
            """
        try await runner.loadPlugin(fromBytes: module(.run, payload: [6] + Array("成功".utf8), body: body))
        #expect(try await runner.runSettingsAction("検査") == "成功")
        #expect(try await runner.executeExport("free_count") == [.i32(2)])
    }

    @Test func emptyIDAndSuccessfulEmptyMessageStayDistinctFromUnsupported() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(.run, body: """
            local.get $length if unreachable end
            local.get $id if unreachable end
            i64.const \((UInt64(64) << 32) | 1)
            """))
        #expect(try await runner.runSettingsAction("")?.isEmpty == true)
        #expect(try await runner.executeExport("free_count") == [.i32(1)])
    }

    @Test(arguments: [Operation.actions, .validation])
    func emptySuccessfulArraysAreNotAbsent(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(operation))
        switch operation {
        case .actions: #expect(try await runner.getSettingsActions()?.isEmpty == true)
        case .validation: #expect(try await runner.validateSettings()?.isEmpty == true)
        case .run: Issue.record("Not an array operation")
        }
        #expect(try await runner.executeExport("free_count") == [.i32(1)])
    }

    @Test(arguments: Operation.allCases)
    func explicitUnsupportedOptsOut(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(operation, body: "i64.const 0", failure: .unsupported))
        #expect(try await !operation.invoke(runner))
        #expect(try await runner.executeExport("free_count") == [.i32(operation == .run ? 2 : 1)])
    }

    @Test(arguments: Operation.allCases, [PluginErrorCategory.unauthorized, .server, .other])
    func typedRefusalsCannotBecomeUnsupported(_ operation: Operation, _ category: PluginErrorCategory) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(operation, body: "i64.const 0", failure: category))
        await #expect(throws: ItoError.pluginFailed(
            function: operation.export, reason: "Unsupported operation", category: category
        )) { try await operation.invoke(runner) }
        #expect(try await runner.executeExport("free_count") == [.i32(operation == .run ? 2 : 1)])
    }

    @Test(arguments: Operation.allCases)
    func malformedPayloadsThrowAndFreeReturnedBuffers(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(operation, payload: [128]))
        await #expect(throws: ItoError.self) { try await operation.invoke(runner) }
        #expect(try await runner.executeExport("free_count") == [.i32(operation == .run ? 2 : 1)])
    }

    @Test func trappingActionStillFreesItsInput() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(.run, body: "unreachable"))
        await #expect(throws: ItoError.self) { try await runner.runSettingsAction("検査") }
        #expect(try await runner.executeExport("free_count") == [.i32(1)])
    }
}

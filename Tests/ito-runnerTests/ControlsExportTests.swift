import Foundation
import Testing
import WAT
import WasmKit
@testable import ito_runner

private func watBytes(_ bytes: [UInt8]) -> String { bytes.map { String(format: "\\%02x", $0) }.joined() }
private func packed(_ pointer: UInt64, _ count: Int) -> UInt64 { (pointer << 32) | UInt64(count) }

/// Small ABI-2 module with independently observable call/deallocation counters.
private func controlsModule(exports: String, data: [UInt8] = [0], abi: Int = 2,
                            failure: PluginErrorCategory? = nil) throws -> [UInt8] {
    var failureExports = ""
    if let failure {
        let report = try ItoPostcardEncoder().encode(PluginErrorPayload(category: failure, message: "Unsupported operation"))
        failureExports = """
        (data (i32.const 512) "\(watBytes(report))")
        (func (export "ito_error_version") (result i32) i32.const 2)
        (func (export "ito_last_error") (result i64) i64.const \(packed(512, report.count)))
        """
    }
    return try wat2wasm("""
        (module
            (memory (export "memory") 16)
            (global $calls (mut i32) (i32.const 0))
            (global $legacy (mut i32) (i32.const 0))
            (global $frees (mut i32) (i32.const 0))
            (func (export "ito_abi_version") (result i32) i32.const \(abi))
            (func (export "ito_supported_kinds") (result i32) i32.const 7)
            (func (export "alloc") (param i32) (result i32) i32.const 8192)
            (func (export "dealloc") (param i32 i32)
                global.get $frees i32.const 1 i32.add global.set $frees)
            (func (export "calls") (result i32) global.get $calls)
            (func (export "legacy_calls") (result i32) global.get $legacy)
            (func (export "frees") (result i32) global.get $frees)
            (data (i32.const 1024) "\(watBytes(data))")
            \(failureExports)
            \(exports)
        )
        """)
}
private let countCall = "global.get $calls i32.const 1 i32.add global.set $calls"
private let legacySettings = """
    (data (i32.const 64) "\\00")
    (func (export "get_settings") (result i64)
        global.get $legacy i32.const 1 i32.add global.set $legacy
        i64.const 274877906945)
    """

@Suite("Bounded rich-controls exports")
struct ControlsExportTests {
    enum Operation: CaseIterable, Sendable {
        case form, capabilities, page, suggestions
        var name: String {
            switch self { case .form: "get_settings_form"; case .capabilities: "get_search_capabilities"; case .page: "get_option_page"; case .suggestions: "get_search_suggestions" }
        }
        var parameters: String {
            switch self { case .form: ""; case .capabilities: "(param i32)"; case .page: "(param i32 i32)"; case .suggestions: "(param i32 i32 i32)" }
        }
        var budget: Int {
            switch self { case .form: 262144; case .capabilities: 262144; case .page: 131072; case .suggestions: 16384 }
        }
        func invoke(_ runner: ItoRunner) async throws {
            switch self {
            case .form: _ = try await runner.getSettingsSurface()
            case .capabilities: _ = try await runner.getSearchCapabilities(kind: nil)
            case .page: _ = try await runner.getOptionPage(OptionRequest(catalog: "tags", query: .search(text: "", offset: 0), limit: 50))
            case .suggestions: _ = try await runner.getSearchSuggestions(query: "query", kind: nil)
            }
        }
        var capabilitySupport: String {
            self == .suggestions ? """
            (data (i32.const 128) "\\08\\00\\00")
            (func (export "get_search_capabilities") (param i32) (result i64) i64.const 549755813891)
            """ : ""
        }
    }
    @Test(arguments: Operation.allCases)
    func missingExports(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: ""))
        try await operation.invoke(runner)
        #expect(try await runner.executeExport("calls") == [.i32(0)])
    }
    @Test(arguments: Operation.allCases)
    func wrongSignatureIsRejectedWithoutCalling(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: """
            \(operation.capabilitySupport)
            (func (export "\(operation.name)") (param i64) (result i64) \(countCall) i64.const 0)
            """))
        await #expect(throws: ItoError.controlContractViolation(function: operation.name, violation: .init(.signature))) {
            try await operation.invoke(runner)
        }
        #expect(try await runner.executeExport("calls") == [.i32(0)])
    }
    @Test(arguments: Operation.allCases)
    func oversizeResultsAreFreedBeforeAnyMemoryRead(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: """
            \(operation.capabilitySupport)
            (func (export "\(operation.name)") \(operation.parameters) (result i64)
                i64.const \(packed(0xfffffff0, operation.budget + 1)))
            """))
        await #expect(throws: ItoError.controlContractViolation(function: operation.name, violation: .init(.responseTooLarge))) {
            try await operation.invoke(runner)
        }
        let frees = operation == .suggestions ? UInt32(3) : operation == .page ? 2 : 1
        #expect(try await runner.executeExport("frees") == [.i32(frees)])
    }
    @Test(arguments: Operation.allCases)
    func malformedResultsAreFreed(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: """
            \(operation.capabilitySupport)
            (func (export "\(operation.name)") \(operation.parameters) (result i64) i64.const \(packed(1024, 1)))
            """, data: [128]))
        await #expect(throws: ItoError.self) { try await operation.invoke(runner) }
        let frees = operation == .suggestions ? UInt32(3) : operation == .page ? 2 : 1
        #expect(try await runner.executeExport("frees") == [.i32(frees)])
    }
    @Test(arguments: Operation.allCases, [PluginErrorCategory.unsupported, .unauthorized, .other])
    func typedFailureProtocol(_ operation: Operation, _ category: PluginErrorCategory) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: """
            \(operation.capabilitySupport)
            (func (export "\(operation.name)") \(operation.parameters) (result i64) i64.const 0)
            """, failure: category))
        if category == .unsupported { try await operation.invoke(runner) }
        else {
            await #expect(throws: ItoError.pluginFailed(function: operation.name, reason: "Unsupported operation", category: category)) {
                try await operation.invoke(runner)
            }
        }
    }
    @Test(arguments: Operation.allCases)
    func abiOneNeverCallsNewExports(_ operation: Operation) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: """
            \(operation.capabilitySupport)
            (func (export "\(operation.name)") \(operation.parameters) (result i64) unreachable)
            """, abi: 1))
        try await operation.invoke(runner)
    }
    @Test func invalidRequestIsRejectedBeforeAllocation() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: ""))
        await #expect(throws: ItoError.controlContractViolation(function: "get_option_page", violation: .init(.requestInvalid))) {
            try await runner.getOptionPage(OptionRequest(catalog: "bad id", query: .values([]), limit: 0))
        }
        #expect(try await runner.executeExport("frees") == [.i32(0)])
    }

    @Test func optionRequestAndValidResponseCrossTheBoundary() async throws {
        let runner = ItoRunner()
        let request = OptionRequest(catalog: "tags", query: .values(["t1", "t9"]), limit: 2)
        let expected = try ItoPostcardEncoder().encode(request)
        let page = OptionPage(options: [ChoiceOption(value: "t1", label: "Romance", group: "Themes")], total: 1, revision: "r1")
        let bytes = try ItoPostcardEncoder().encode(page)
        let checks = expected.enumerated().map { index, byte in
            "local.get $request i32.const \(index) i32.add i32.load8_u i32.const \(byte) i32.ne if unreachable end"
        }.joined(separator: "\n")
        try await runner.loadPlugin(fromBytes: controlsModule(exports: """
            (func (export "get_option_page") (param $request i32) (param $length i32) (result i64)
                local.get $length i32.const \(expected.count) i32.ne if unreachable end
                \(checks)
                i64.const \(packed(1024, bytes.count)))
            """, data: bytes))
        #expect(try await runner.getOptionPage(request) == page)
        #expect(try await runner.executeExport("frees") == [.i32(2)])
    }

    @Test func successfulSuggestionsPreserveEmptyAndNonemptyResults() async throws {
        let runner = ItoRunner()
        for suggestions in [[], [SearchSuggestion(query: "Frieren", subtitle: "Title")]] {
            let bytes = try ItoPostcardEncoder().encode(suggestions)
            try await runner.loadPlugin(fromBytes: controlsModule(exports: """
                \(Operation.suggestions.capabilitySupport)
                (func (export "get_search_suggestions") (param i32 i32) (param $kind i32) (result i64)
                    local.get $kind i32.const 2 i32.ne if unreachable end
                    i64.const \(packed(1024, bytes.count)))
                """, data: bytes))
            #expect(try await runner.getSearchSuggestions(query: "fri", kind: .novel) == suggestions)
            #expect(try await runner.executeExport("frees") == [.i32(3)])
        }
    }

    @Test func aNonFunctionExportIsASignatureViolation() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: "(global (export \"get_settings_form\") i32 (i32.const 0))"))
        await #expect(throws: ItoError.controlContractViolation(function: "get_settings_form", violation: .init(.signature))) {
            try await runner.getSettingsSurface()
        }
    }
}

@Suite("Settings surface precedence")
struct SettingsSurfaceTests {
    @Test func validFormDoesNotCallLegacy() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: legacySettings + """
            (func (export "get_settings_form") (result i64) i64.const \(packed(1024, 1)))
            """))
        guard case .form(let form) = try await runner.getSettingsSurface() else { Issue.record("Expected form"); return }
        #expect(form.sections.isEmpty)
        #expect(try await runner.executeExport("legacy_calls") == [.i32(0)])
    }
    @Test(arguments: [false, true])
    func absentOrUnsupportedFormUsesLegacy(_ unsupported: Bool) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: legacySettings + (unsupported ? "(func (export \"get_settings_form\") (result i64) i64.const 0)" : ""), failure: unsupported ? .unsupported : nil))
        guard case .legacy(let schema, let failure) = try await runner.getSettingsSurface() else { Issue.record("Expected legacy"); return }
        #expect(schema.settings.isEmpty)
        #expect(failure == nil)
        #expect(try await runner.executeExport("legacy_calls") == [.i32(1)])
    }
    @Test func invalidFormCarriesFailureOnlyWhenLegacyExists() async throws {
        let runner = ItoRunner()
        let form = "(func (export \"get_settings_form\") (result i64) i64.const \(packed(1024, 1)))"
        try await runner.loadPlugin(fromBytes: controlsModule(exports: legacySettings + form, data: [33]))
        guard case .legacy(_, let failure) = try await runner.getSettingsSurface() else { Issue.record("Expected legacy"); return }
        #expect(failure == .controlContractViolation(function: "get_settings_form", violation: .init(.countSections)))
        try await runner.loadPlugin(fromBytes: controlsModule(exports: form, data: [33]))
        await #expect(throws: ItoError.controlContractViolation(function: "get_settings_form", violation: .init(.countSections))) { try await runner.getSettingsSurface() }
    }
    @Test func trapsNeverFallBack() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: legacySettings + "(func (export \"get_settings_form\") (result i64) unreachable)"))
        await #expect(throws: ItoError.self) { try await runner.getSettingsSurface() }
        #expect(try await runner.executeExport("legacy_calls") == [.i32(0)])
    }
}

@Suite("Dense search transport")
struct SearchFiltersTransportTests {
    private func searchModule(capabilities: SearchCapabilities?, expected: [UInt8], failure: Bool = false) throws -> [UInt8] {
        let payload = try capabilities.map { try ItoPostcardEncoder().encode($0) } ?? [0]
        let checks = expected.enumerated().map { index, byte in
            "local.get $filters i32.const \(index) i32.add i32.load8_u i32.const \(byte) i32.ne if unreachable end"
        }.joined(separator: "\n")
        return try controlsModule(exports: """
            \(capabilities != nil || failure ? "(func (export \"get_search_capabilities\") (param i32) (result i64) \(countCall) i64.const \(failure ? 0 : packed(1024, payload.count)))" : "")
            (data (i32.const 64) "\\00\\00")
            (func (export "search") (param i32 i32 i32 i32) (param $filters i32) (param $length i32) (result i64)
                local.get $length i32.const \(expected.count) i32.ne if unreachable end
                \(checks)
                i64.const \(packed(64, 2)))
            """, data: payload, failure: failure ? .unauthorized : nil)
    }
    @Test func noCapabilitiesSendsExactlyEmptyVector() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: searchModule(capabilities: nil, expected: [0]))
        _ = try await runner.search(query: "query", page: 1, filterValues: ["x": .toggle(true)])
    }
    @Test func denseDefaultsAreCachedPerKindAndReloadClearsCache() async throws {
        let c = Control(id: "adult", title: "Adult", kind: .toggle(ToggleControl(defaultValue: false)))
        let caps = SearchCapabilities(sections: [ControlSection(id: "s", title: "S", controls: [c])])
        let expected = try ItoPostcardEncoder().encode(caps.filterItems(values: [:]))
        let wasm = try searchModule(capabilities: caps, expected: expected)
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wasm)
        _ = try await runner.search(query: "q", page: 1, kind: .manga)
        _ = try await runner.search(query: "q", page: 2, kind: .manga)
        _ = try await runner.getSearchCapabilities(kind: .manga)
        #expect(try await runner.executeExport("calls") == [.i32(1)])
        _ = try await runner.search(query: "q", page: 1, kind: .anime)
        #expect(try await runner.executeExport("calls") == [.i32(2)])
        try await runner.loadPlugin(fromBytes: wasm)
        _ = try await runner.search(query: "q", page: 1, kind: .manga)
        #expect(try await runner.executeExport("calls") == [.i32(1)])
    }
    @Test func failuresAreCachedButSearchStillUsesEmptyFilters() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: searchModule(capabilities: nil, expected: [0], failure: true))
        for _ in 0..<2 { _ = try await runner.search(query: "q", page: 1) }
        await #expect(throws: ItoError.self) { try await runner.getSearchCapabilities(kind: nil) }
        #expect(try await runner.executeExport("calls") == [.i32(1)])
    }
    @Test func suggestionsRequireCapabilityAndBoundedQuery() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: controlsModule(exports: "(func (export \"get_search_suggestions\") (param i32 i32 i32) (result i64) unreachable)"))
        #expect(try await runner.getSearchSuggestions(query: "q", kind: nil) == nil)
        #expect(try await runner.getSearchSuggestions(query: "", kind: nil) == nil)
        #expect(try await runner.getSearchSuggestions(query: String(repeating: "x", count: 257), kind: nil) == nil)
    }
}

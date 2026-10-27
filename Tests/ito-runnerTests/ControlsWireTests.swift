import Foundation
import Testing
@testable import ito_runner

private struct ControlsFixtures: Decodable {
    struct Wire: Decodable {
        let name: String
        let type: String
        let direction: String
        let hex: String
        let expect: String
        let request: String?
        var bytes: [UInt8] {
            stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
        }
    }
    enum Scalar: Decodable {
        case integer(Int64), boolean(Bool), text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let value = try? c.decode(Bool.self) { self = .boolean(value) }
            else if let value = try? c.decode(Int64.self) { self = .integer(value) }
            else { self = .text(try c.decode(String.self)) }
        }
    }
    struct Value: Decodable {
        let kind: String
        let canonical: String
        let invalid: Bool?
        let items: [String]?
        let value: Scalar?
        let lower: Int64?
        let upper: Int64?
    }
    let contract: String
    let version: Int
    let wire: [Wire]
    let values: [Value]
    static func load() throws -> Self {
        let url = Bundle.module.url(forResource: "controls-v1", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@Suite("Rich controls shared wire fixtures")
struct ControlsWireTests {
    @Test func requiredFixtureInventoryIsComplete() throws {
        let required = [
            "settings_form.empty", "settings_form.one_toggle", "settings_form.all_kinds", "settings_form.flags",
            "control.multi_select_catalog", "control.integer", "control.unknown_kind_99", "control.unknown_kind_empty_body",
            "search_capabilities.sort_only", "search_capabilities.full", "option_page.first", "option_page.values",
            "suggestions.one", "suggestions.empty", "settings_form.duplicate_control", "settings_form.bad_id",
            "settings_form.too_many_sections", "control.select_default_missing", "control.min_gt_max",
            "control.condition_on_conditional", "control.condition_toggle_value", "control.body_trailing_byte",
            "search_capabilities.secret_filter", "search_capabilities.sort_catalog", "option_page.no_progress",
            "option_page.unrequested_value", "option_page.too_many_options", "option_request.search",
            "option_request.values", "filters.dense", "filters.empty"
        ]
        let names = try ControlsFixtures.load().wire.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(required).isSubset(of: Set(names)))
    }

    @Test func denseTransportMatchesSharedRustFixture() throws {
        let fixtures = try ControlsFixtures.load()
        let capabilityWire = try #require(fixtures.wire.first { $0.name == "search_capabilities.full" })
        let filterWire = try #require(fixtures.wire.first { $0.name == "filters.dense" })
        let capabilities = try ControlsDecoder.searchCapabilities(capabilityWire.bytes)
        let values: [String: ControlValue] = [
            "sort": .select("title"), "adult": .toggle(false),
            "year": .integerRange(lower: 2101, upper: nil), "tags": .multiSelect(["t9"])
        ]
        let items = capabilities.filterItems(values: values)
        #expect(try ItoPostcardEncoder().encode(items) == filterWire.bytes)
        #expect(items.map(\.name) == ["sort", "adult", "year", "genres", "tags"])
    }

    private func roundTrip<T: Codable>(_ type: T.Type, _ bytes: [UInt8]) throws -> T {
        let value = try ItoPostcardDecoder().decode(type, from: bytes)
        #expect(try ItoPostcardEncoder().encode(value) == bytes)
        return value
    }
    @Test func everySharedWireFixture() throws {
        let fixtures = try ControlsFixtures.load()
        #expect(fixtures.contract == "ito-controls")
        #expect(fixtures.version == 1)
        for fixture in fixtures.wire {
            do {
                switch fixture.type {
                case "SettingsForm":
                    let form = try ControlsDecoder.settingsForm(fixture.bytes)
                    #expect(try ItoPostcardEncoder().encode(form) == fixture.bytes, Comment(rawValue: fixture.name))
                    if fixture.name == "settings_form.one_toggle" {
                        #expect(form.sections == [ControlSection(id: "content", title: "Content", controls: [Control(id: "adult", title: "Adult", kind: .toggle(ToggleControl(defaultValue: false)))])])
                    }
                    if fixture.name == "settings_form.all_kinds" {
                        #expect(form.controls.map(\.kind.tag) == [0, 1, 2, 3, 4, 5, 6, 4])
                        #expect(form.sections[0].summary == "All controls")
                        #expect(form.sections[0].flags.contains(.page))
                        #expect(form.controls[1].kind == .text(TextControl(
                            defaultValue: "https://example.test\npath", placeholder: "Enter a URL", flags: [.url, .multiline])))
                        #expect(form.controls[2].kind == .secret(SecretControl(placeholder: "Credential")))
                        #expect(form.controls[5].kind == .integer(IntegerControl(min: -10, max: 10, defaultValue: 0, unit: "items")))
                        #expect(form.controls[6].kind == .integerRange(IntegerRangeControl(
                            min: 1900, max: 2100, defaultLower: 2015, defaultUpper: 2024, unit: "year")))
                        #expect(form.controls[7].visibleWhen == [ControlCondition(control: "adult", anyOf: ["true"])])
                    }
                    if fixture.name == "settings_form.flags" {
                        #expect(form.sections[0].flags.rawValue == 0x80000001)
                        if case .text(let text) = form.controls[0].kind { #expect(text.flags == [.url, .multiline]) }
                        else { Issue.record("Expected text control") }
                    }
                case "Control":
                    let control = try ItoPostcardDecoder().decode(Control.self, from: fixture.bytes)
                    if fixture.expect.hasPrefix("unsupported:") {
                        let tag = UInt32(fixture.expect.split(separator: ":")[1])!
                        #expect(control.kind == .unsupported(tag: tag))
                        #expect(throws: ItoError.self) { try ItoPostcardEncoder().encode(control) }
                        continue
                    }
                    var count = 0
                    try ControlValidation.control(control, search: false, optionsTotal: &count)
                    #expect(try ItoPostcardEncoder().encode(control) == fixture.bytes)
                    if fixture.name == "control.integer" {
                        #expect(control == Control(id: "year", title: "Year", kind: .integer(IntegerControl(min: 1900, max: 2100))))
                    }
                    if fixture.name == "control.multi_select_catalog" {
                        #expect(control.kind == .multiSelect(MultiSelectControl(
                            options: .catalog(OptionCatalog(id: "tags", flags: [.searchable])), defaultValue: [])))
                        #expect(control.visibleWhen == [ControlCondition(control: "adult", anyOf: ["true"])])
                    }
                case "SearchCapabilities":
                    let capabilities = try ControlsDecoder.searchCapabilities(fixture.bytes)
                    #expect(try ItoPostcardEncoder().encode(capabilities) == fixture.bytes)
                    if fixture.name == "search_capabilities.sort_only" {
                        #expect(capabilities.flags.rawValue == 5)
                        #expect(capabilities.sort?.id == "sort")
                        #expect(capabilities.sort?.kind.defaultValue == .select("views"))
                    }
                    if fixture.name == "search_capabilities.full" {
                        #expect(capabilities.flags.rawValue == 0x8000000f)
                        #expect(capabilities.controls.map(\.id) == ["sort", "adult", "year", "genres", "tags"])
                        #expect(capabilities.controls.map(\.kind.tag) == [3, 0, 6, 4, 4])
                    }
                case "OptionRequest":
                    let request = try roundTrip(OptionRequest.self, fixture.bytes)
                    try ControlValidation.request(request)
                    if fixture.name == "option_request.search" {
                        #expect(request == OptionRequest(catalog: "tags", query: .search(text: "ro", offset: 50), limit: 50))
                    } else if fixture.name == "option_request.values" {
                        #expect(request == OptionRequest(catalog: "tags", query: .values(["t1", "t9"]), limit: 2))
                    }
                case "OptionPage":
                    let requestWire = try #require(fixtures.wire.first { $0.name == fixture.request })
                    let request = try ItoPostcardDecoder().decode(OptionRequest.self, from: requestWire.bytes)
                    let page = try ControlsDecoder.optionPage(fixture.bytes, request: request)
                    #expect(try ItoPostcardEncoder().encode(page) == fixture.bytes)
                    if fixture.name == "option_page.first" {
                        #expect(page == OptionPage(options: [ChoiceOption(value: "t1", label: "Romance", group: "Themes")], nextOffset: 51, total: 6141))
                    }
                case "Suggestions":
                    let suggestions = try ControlsDecoder.suggestions(fixture.bytes)
                    #expect(try ItoPostcardEncoder().encode(suggestions) == fixture.bytes)
                    if fixture.name == "suggestions.one" { #expect(suggestions == [SearchSuggestion(query: "Frieren")]) }
                case "Filters":
                    let filters = try roundTrip([FilterItem].self, fixture.bytes)
                    #expect(filters.allSatisfy { if case .string = $0.value { return true }; return false })
                default: Issue.record("Unrecognized fixture payload type")
                }
                #expect(fixture.expect == "ok")
            } catch let v as ControlContractViolation {
                let expected = fixture.expect.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                #expect(expected.first == "violation")
                #expect(expected.count >= 2 && expected[1] == v.rule.rawValue)
                if expected.count > 2 { #expect(v.id == expected[2]) }
            }
        }
    }
    @Test func everySharedCanonicalValueFixture() throws {
        let fixtures = try ControlsFixtures.load()
        for fixture in fixtures.values {
            let kind: ControlKind
            switch fixture.kind {
            case "toggle": kind = .toggle(ToggleControl(defaultValue: false))
            case "integer": kind = .integer(IntegerControl(min: .min, max: .max))
            case "multi_select": kind = .multiSelect(MultiSelectControl(options: .catalog(OptionCatalog(id: "tags")), defaultValue: []))
            case "integer_range": kind = .integerRange(IntegerRangeControl(min: .min, max: .max))
            default: Issue.record("Unrecognized fixture value kind"); continue
            }
            let decoded = ControlValueCodec.decode(fixture.canonical, for: kind)
            if fixture.invalid == true { #expect(decoded == nil) }
            else {
                #expect(decoded != nil)
                #expect(decoded.map(ControlValueCodec.canonical) == fixture.canonical)
                if let items = fixture.items { #expect(decoded == .multiSelect(items)) }
                if case .integer(let value)? = fixture.value { #expect(decoded == .integer(value)) }
                if case .boolean(let value)? = fixture.value { #expect(decoded == .toggle(value)) }
                if case .integerRange = kind { #expect(decoded == .integerRange(lower: fixture.lower, upper: fixture.upper)) }
            }
        }
    }
    @Test func unknownKindKeepsSiblingControlsAndUnknownFlags() throws {
        let future: [UInt8] = [6] + Array("future".utf8) + [6] + Array("Future".utf8) + [0, 0, 0, 99, 2, 0xaa, 0xbb]
        let toggle = Control(id: "adult", title: "Adult", kind: .toggle(ToggleControl(defaultValue: false)))
        let second = try ItoPostcardEncoder().encode(toggle)
        let prefix: [UInt8] = [1, 1, 115, 1, 83, 0, 0, 2]
        let form = try ControlsDecoder.settingsForm(prefix + future + second)
        #expect(form.controls.map(\.id) == ["future", "adult"])
        #expect(form.controls.first?.kind == .unsupported(tag: 99))
        let flagged = SettingsForm(sections: [ControlSection(id: "s", title: "S", flags: .init(rawValue: 0x80000001), controls: [toggle])])
        let restored = try ControlsDecoder.settingsForm(ItoPostcardEncoder().encode(flagged))
        #expect(restored.sections[0].flags.rawValue == 0x80000001)
        #expect(restored.sections[0].flags.contains(.page))
    }

    @Test func kindBodyBoundsAndTrailingBytes() throws {
        // Header only; the deliberately absent oversized body must not be copied or decoded.
        let header: [UInt8] = [1, 120, 1, 88, 0, 0, 0]
        #expect(throws: ControlContractViolation(.lengthBody)) {
            try ItoPostcardDecoder().decode(Control.self, from: header + [99, 0x81, 0x80, 0x04])
        }
        let body = try ItoPostcardEncoder().encode([UInt8](repeating: 0, count: ControlLimits.bodyBytes))
        let future = try ItoPostcardDecoder().decode(Control.self, from: header + [99] + body)
        #expect(future.kind == .unsupported(tag: 99))
        #expect(throws: ControlContractViolation(.controlBody, id: "x")) {
            try ItoPostcardDecoder().decode(Control.self, from: header + [0, 2, 0, 0])
        }
        #expect(throws: ControlContractViolation(.controlBody, id: "x")) {
            try ItoPostcardDecoder().decode(Control.self, from: header + [0, 0])
        }
    }
}

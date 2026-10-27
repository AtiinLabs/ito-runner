import Testing
@testable import ito_runner

@Suite("Controls contract validation")
struct ControlsValidationTests {
    func control(_ id: String = "x", kind: ControlKind = .toggle(ToggleControl(defaultValue: false))) -> Control {
        Control(id: id, title: "Title", kind: kind)
    }
    func validate(_ controls: [Control]) throws {
        try ControlValidation.document(sections: [ControlSection(id: "s", title: "Section", controls: controls)])
    }
    func rejects(_ rule: ControlContractViolation.Rule, _ body: () throws -> Void) {
        #expect(throws: ControlContractViolation.self) { try body() }
        do { try body() } catch let v as ControlContractViolation { #expect(v.rule == rule) } catch { Issue.record("Unexpected error type") }
    }
    @Test func identifierBoundariesAndPrivacy() throws {
        try ControlValidation.identifier(String(repeating: "a", count: 64))
        rejects(.lengthId) { try ControlValidation.identifier("") }
        rejects(.lengthId) { try ControlValidation.identifier(String(repeating: "a", count: 65)) }
        rejects(.charsId) { try ControlValidation.identifier("invalid id") }
        #expect(ControlContractViolation(.controlBody, id: "private value").id == nil)
        #expect(ControlContractViolation(.controlBody, id: "valid-id").description == "control.body (valid-id)")
    }
    @Test func humanTextBoundaries() throws {
        let fields: [(Int, ControlContractViolation.Rule)] = [(256, .lengthTitle), (1024, .lengthSummary), (256, .lengthLabel), (128, .lengthGroup), (128, .lengthPlaceholder), (32, .lengthUnit), (256, .lengthQuery), (256, .lengthSubtitle)]
        for (max, rule) in fields {
            try ControlValidation.human(String(repeating: "a", count: max), max: max, rule: rule)
            rejects(rule) { try ControlValidation.human(String(repeating: "a", count: max + 1), max: max, rule: rule) }
            rejects(rule) { try ControlValidation.human("", max: max, rule: rule) }
        }
        for scalar in ["\u{00}", "\u{1f}", "\u{7f}", "\u{80}", "\u{9f}", "\n"] {
            rejects(.charsText) { try ControlValidation.human(scalar, max: 10, rule: .lengthTitle) }
        }
        try ControlValidation.human("a\nb", max: 10, rule: .lengthSummary, newline: true)
    }
    @Test func valueBoundaries() throws {
        try ControlValidation.value(String(repeating: "a", count: 256))
        try ControlValidation.value("\u{80}")
        rejects(.lengthValue) { try ControlValidation.value("") }
        rejects(.lengthValue) { try ControlValidation.value(String(repeating: "a", count: 257)) }
        rejects(.charsValue) { try ControlValidation.value("\u{7f}") }
        rejects(.duplicateValue) { try ControlValidation.values(["a", "a"]) }
    }
    @Test func sectionAndControlCountsAndDuplicates() throws {
        let sections = (0..<32).map { ControlSection(id: "s\($0)", title: "S", controls: []) }
        try ControlValidation.document(sections: sections)
        rejects(.countSections) { try ControlValidation.document(sections: sections + [ControlSection(id: "extra", title: "S", controls: [])]) }
        rejects(.duplicateSection) { try ControlValidation.document(sections: [sections[0], sections[0]]) }
        try validate((0..<64).map { control("c\($0)") })
        rejects(.countSectionControls) { try validate((0..<65).map { control("c\($0)") }) }
        rejects(.duplicateControl) { try validate([control(), control()]) }
        let full = (0..<4).map { section in ControlSection(id: "s\(section)", title: "S", controls: (0..<64).map { control("c\(section)_\($0)") }) }
        try ControlValidation.document(sections: full)
        rejects(.countControls) { try ControlValidation.document(sections: full + [ControlSection(id: "last", title: "S", controls: [control("extra")])]) }
    }
    @Test func optionsCountsDefaultsAndSelectionCap() throws {
        let options = (0..<256).map { ChoiceOption(value: "v\($0)", label: "V") }
        let valid = ControlKind.select(SelectControl(options: .inline(options), defaultValue: "v0"))
        try validate([control(kind: valid)])
        rejects(.countOptions) { try validate([control(kind: .select(SelectControl(options: .inline([]))))]) }
        rejects(.countOptions) { try validate([control(kind: .select(SelectControl(options: .inline(options + [ChoiceOption(value: "extra", label: "V")]))))]) }
        rejects(.duplicateOption) { try ControlValidation.options([options[0], options[0]]) }
        rejects(.controlDefault) { try validate([control(kind: .select(SelectControl(options: .inline(options), defaultValue: "missing")))]) }
        try validate((0..<8).map { control("c\($0)", kind: valid) })
        rejects(.countFormOptions) { try validate((0..<9).map { control("c\($0)", kind: valid) }) }
        let source = OptionSource.catalog(OptionCatalog(id: "catalog"))
        for cap in [UInt32(0), 501] {
            rejects(.controlMaxSelected) { try validate([control(kind: .multiSelect(MultiSelectControl(options: source, defaultValue: [], maxSelected: cap)))]) }
        }
        try validate([control(kind: .multiSelect(MultiSelectControl(options: source, defaultValue: [], maxSelected: 500)))])
        rejects(.controlMaxSelected) { try validate([control(kind: .multiSelect(MultiSelectControl(options: source, defaultValue: ["a", "b"], maxSelected: 1)))]) }
        rejects(.countDefaultValues) { try validate([control(kind: .multiSelect(MultiSelectControl(options: source, defaultValue: (0..<65).map { "v\($0)" })))]) }
        rejects(.controlDefault) { try validate([control(kind: .multiSelect(MultiSelectControl(options: .inline([options[0]]), defaultValue: ["missing"])))]) }
    }
    @Test func boundsDefaultsTextAndContext() throws {
        rejects(.controlBounds) { try validate([control(kind: .integer(IntegerControl(min: 2, max: 1)))]) }
        rejects(.controlDefault) { try validate([control(kind: .integer(IntegerControl(min: 1, max: 2, defaultValue: 3)))]) }
        rejects(.controlDefault) { try validate([control(kind: .integerRange(IntegerRangeControl(min: 1, max: 2, defaultLower: 2, defaultUpper: 1)))]) }
        rejects(.controlBounds) { try validate([control(kind: .integerRange(IntegerRangeControl(min: 2, max: 1)))]) }
        try validate([control(kind: .text(TextControl(defaultValue: String(repeating: "a", count: 4096))))])
        rejects(.lengthDefault) { try validate([control(kind: .text(TextControl(defaultValue: String(repeating: "a", count: 4097))))]) }
        rejects(.charsText) { try validate([control(kind: .text(TextControl(defaultValue: "a\nb")))]) }
        try validate([control(kind: .text(TextControl(defaultValue: "a\nb", flags: [.multiline])) )])
        rejects(.controlContext) { try ControlValidation.document(sections: [ControlSection(id: "s", title: "S", controls: [control(kind: .secret(SecretControl()))])], search: true) }
        rejects(.controlContext) { try ControlValidation.document(sections: [], sort: control(), search: true) }
    }
    @Test func conditionsAndDepthOne() throws {
        let target = control("target")
        var dependent = control("dependent")
        dependent.visibleWhen = [ControlCondition(control: "target", anyOf: ["true"])]
        try validate([target, dependent])
        dependent.visibleWhen[0].anyOf = ["other"]
        rejects(.conditionValue) { try validate([target, dependent]) }
        dependent.visibleWhen[0].control = "missing"
        rejects(.conditionTarget) { try validate([target, dependent]) }
        dependent.visibleWhen[0].control = "dependent"
        rejects(.conditionTarget) { try validate([target, dependent]) }
        dependent.visibleWhen = [ControlCondition(control: "target", anyOf: [])]
        rejects(.countConditionValues) { try validate([target, dependent]) }
        dependent.visibleWhen = [ControlCondition(control: "target", anyOf: (0..<17).map { "v\($0)" })]
        rejects(.countConditionValues) { try validate([target, dependent]) }
        dependent.visibleWhen = Array(repeating: ControlCondition(control: "target", anyOf: ["true"]), count: 5)
        rejects(.countConditions) { try validate([target, dependent]) }
        dependent.visibleWhen.removeLast()
        try validate([target, dependent])
        var grandchild = control("grandchild")
        grandchild.visibleWhen = [ControlCondition(control: "dependent", anyOf: ["true"])]
        rejects(.conditionTarget) { try validate([target, dependent, grandchild]) }
    }
    @Test func requestAndPageRules() throws {
        let request = OptionRequest(catalog: "tags", query: .search(text: "", offset: 50), limit: 1)
        try ControlValidation.request(request)
        rejects(.requestInvalid) { try ControlValidation.request(OptionRequest(catalog: "bad id", query: .values(["a"]), limit: 1)) }
        rejects(.requestInvalid) { try ControlValidation.request(OptionRequest(catalog: "tags", query: .values(["a"]), limit: 2)) }
        for limit in [UInt32(0), 101] { rejects(.requestInvalid) { try ControlValidation.request(OptionRequest(catalog: "tags", query: .search(text: "", offset: 0), limit: limit)) } }
        rejects(.requestInvalid) { try ControlValidation.request(OptionRequest(catalog: "tags", query: .search(text: String(repeating: "a", count: 257), offset: 0), limit: 1)) }
        let option = ChoiceOption(value: "a", label: "A")
        rejects(.pageProgress) { try ControlValidation.page(OptionPage(options: [option], nextOffset: 50), request: request) }
        rejects(.countPageOptions) { try ControlValidation.page(OptionPage(options: [option, option]), request: request) }
        let values = OptionRequest(catalog: "tags", query: .values(["b"]), limit: 1)
        rejects(.pageValues) { try ControlValidation.page(OptionPage(options: [option]), request: values) }
        rejects(.pageValues) { try ControlValidation.page(OptionPage(options: [], nextOffset: 1), request: values) }
        rejects(.lengthRevision) { try ControlValidation.page(OptionPage(options: [], revision: ""), request: request) }
        rejects(.charsText) { try ControlValidation.page(OptionPage(options: [], revision: "bad revision"), request: request) }
        try ControlValidation.page(OptionPage(options: [], revision: String(repeating: "x", count: 64)), request: request)
    }
    @Test func prefixLimitsPrecedeElementDecoding() {
        rejects(.countSections) { _ = try ControlsDecoder.settingsForm([33]) }
        let sectionPrefix: [UInt8] = [1, 1, 115, 1, 83, 0, 0, 65]
        rejects(.countSectionControls) { _ = try ControlsDecoder.settingsForm(sectionPrefix) }
        let request = OptionRequest(catalog: "tags", query: .search(text: "", offset: 0), limit: 1)
        rejects(.countPageOptions) { _ = try ControlsDecoder.optionPage([2], request: request) }
        rejects(.countSuggestions) { _ = try ControlsDecoder.suggestions([21]) }
    }
}

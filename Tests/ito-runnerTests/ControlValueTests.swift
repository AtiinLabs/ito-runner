import Testing
@testable import ito_runner

@Suite("Canonical controls values")
struct ControlValueTests {
    let toggle = ControlKind.toggle(ToggleControl(defaultValue: false))
    let integer = ControlKind.integer(IntegerControl(min: .min, max: .max))
    let multi = ControlKind.multiSelect(MultiSelectControl(options: .catalog(OptionCatalog(id: "tags")), defaultValue: []))
    let range = ControlKind.integerRange(IntegerRangeControl(min: .min, max: .max))

    @Test(arguments: ["true", "false"])
    func toggleRoundTrip(_ text: String) {
        #expect(ControlValueCodec.decode(text, for: toggle).map(ControlValueCodec.canonical) == text)
    }
    @Test(arguments: ["True", "1", ""])
    func malformedToggle(_ text: String) { #expect(ControlValueCodec.decode(text, for: toggle) == nil) }
    @Test(arguments: ["0", "-42", "9223372036854775807", "-9223372036854775808", ""])
    func integerRoundTrip(_ text: String) {
        #expect(ControlValueCodec.decode(text, for: integer).map(ControlValueCodec.canonical) == text)
    }
    @Test(arguments: ["+1", "01", "-0", " 1", "1.0", "9223372036854775808"])
    func malformedInteger(_ text: String) { #expect(ControlValueCodec.decode(text, for: integer) == nil) }
    @Test(arguments: ["[]", "[\"a\"]", "[\"a,b\",\"c\\\"d\",\"e\\\\f\"]", "[\"日本\",\"🙂\"]", "[\"\\u001f\"]"])
    func multiRoundTrip(_ text: String) {
        #expect(ControlValueCodec.decode(text, for: multi).map(ControlValueCodec.canonical) == text)
    }
    @Test(arguments: ["", "[", "[\"a\" ]", "[\"a\",]", "['a']", "[\"a\",\"a\"]", "[\"\"]", "[\"\\n\"]", "[\"\\u001F\"]", "[\"\\u0041\"]", "[\"\\/\"]", "Action, Romance"])
    func malformedMulti(_ text: String) { #expect(ControlValueCodec.decode(text, for: multi) == nil) }
    @Test(arguments: ["[2015,null]", "[null,2024]", "[null,null]", "[1,1]"])
    func rangeRoundTrip(_ text: String) {
        #expect(ControlValueCodec.decode(text, for: range).map(ControlValueCodec.canonical) == text)
    }
    @Test(arguments: ["[2024,2015]", "[1]", "[1,2,3]", "[ 1,2]", "[01,2]", "[null]"])
    func malformedRange(_ text: String) { #expect(ControlValueCodec.decode(text, for: range) == nil) }

    @Test func escapingIsIndependentOfJSONEncoderConventions() {
        let values = ["\"\\\u{00}\u{1f}", "/日本🙂"]
        #expect(ControlValueCodec.canonical(.multiSelect(values)) == "[\"\\\"\\\\\\u0000\\u001f\",\"/日本🙂\"]")
    }
    @Test func defaultsAndStoredState() {
        let control = Control(id: "x", title: "X", kind: .integer(IntegerControl(min: 1, max: 3, defaultValue: 2)))
        #expect(control.effectiveValue(stored: nil).state == .unset)
        #expect(control.effectiveValue(stored: "3").value == .integer(3))
        #expect(control.effectiveValue(stored: "4").state == .invalid)
        #expect(control.effectiveValue(stored: "4").value == .integer(2))
        #expect(control.effectiveValue(stored: "").value == .integer(nil))
        #expect(!control.kind.accepts(.text("2")))
    }
    @Test func unavailableInlineValuesRemainValid() {
        let kind = ControlKind.select(SelectControl(options: .inline([ChoiceOption(value: "a", label: "A")]), defaultValue: "a"))
        #expect(kind.accepts(.select("gone")))
    }
    @Test func hiddenAndInvalidValuesUseDefaultsInDenseOrder() {
        let adult = Control(id: "adult", title: "Adult", kind: toggle)
        let hidden = Control(id: "tags", title: "Tags", visibleWhen: [ControlCondition(control: "adult", anyOf: ["true"])], kind: multi)
        let year = Control(id: "year", title: "Year", kind: .integer(IntegerControl(min: 1900, max: 2100)))
        let future = Control(id: "future", title: "Future", kind: .unsupported(tag: 99))
        let caps = SearchCapabilities(sections: [ControlSection(id: "filters", title: "Filters", controls: [adult, hidden, year, future])])
        let values: [String: ControlValue] = ["tags": .multiSelect(["a"]), "year": .integer(1), "unknown": .toggle(true)]
        #expect(!caps.visibleControlIDs(values: values).contains("tags"))
        let items = caps.filterItems(values: values)
        #expect(items.map(\.name) == ["adult", "tags", "year"])
        let strings = items.compactMap { item -> String? in if case .string(let s) = item.value { return s }; return nil }
        #expect(strings == ["false", "[]", ""])
        #expect(items.map(\.type) == ["toggle", "multi_select", "integer"])
    }
    @Test func unknownConditionTargetHoldsAndSelectionsUseAnyOverlap() {
        let future = Control(id: "future", title: "Future", kind: .unsupported(tag: 7))
        let dependent = Control(id: "x", title: "X", visibleWhen: [ControlCondition(control: "future", anyOf: ["x"])], kind: toggle)
        let form = SettingsForm(sections: [ControlSection(id: "s", title: "S", controls: [future, dependent])])
        #expect(form.visibleControlIDs { $0.kind.defaultValue } == ["future", "x"])
    }
    @Test func opaqueRuntimeIdentityAndCanonicalBytes() throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let pairs: [(ControlValue, ControlValue)] = [
            (.text(composed), .text(decomposed)),
            (.select(composed), .select(decomposed)),
            (.multiSelect([composed]), .multiSelect([decomposed]))
        ]
        for pair in pairs {
            #expect(pair.0 != pair.1)
            #expect(Set([pair.0, pair.1]).count == 2)
        }
        #expect(ControlValue.select(nil) != .select(""))
        #expect(ControlValue.text(composed) != .select(composed))
        let values = [composed, decomposed]
        let canonical = ControlValueCodec.canonical(.multiSelect(values))
        let decoded = try #require(ControlValueCodec.decode(canonical, for: multi))
        #expect(decoded == .multiSelect(values))
        #expect(ControlValueCodec.canonical(decoded).utf8.elementsEqual(canonical.utf8))
        #expect(multi.accepts(decoded))
        #expect(!multi.accepts(.multiSelect([composed, composed])))
        let control = Control(id: "tags", title: "Tags", kind: multi)
        #expect(control.effectiveValue(stored: canonical).state == .valid)
        #expect(control.effectiveValue(stored: canonical).value == .multiSelect(values))
        let capped = ControlKind.multiSelect(MultiSelectControl(options: .catalog(OptionCatalog(id: "tags")), defaultValue: [], maxSelected: 1))
        #expect(!capped.accepts(decoded))
        #expect(Control(id: "tags", title: "Tags", kind: capped).effectiveValue(stored: canonical).state == .invalid)
        for invalidValues in [
            [String(repeating: "a", count: ControlLimits.valueBytes + 1)],
            (0...ControlLimits.maxSelected).map { "v\($0)" }
        ] {
            let stored = ControlValueCodec.canonical(.multiSelect(invalidValues))
            #expect(ControlValueCodec.decode(stored, for: multi) != nil)
            #expect(control.effectiveValue(stored: stored).state == .invalid)
            #expect(control.effectiveValue(stored: stored).value == .multiSelect([]))
        }
    }

    @Test(arguments: ["\u{00}", "\u{1f}", "\u{7f}", "\u{80}", "\u{9f}"])
    func syntaxRecognizesButRuntimeRejectsControlCharacters(_ value: String) throws {
        let canonical = ControlValueCodec.canonical(.multiSelect([value]))
        let decoded = try #require(ControlValueCodec.decode(canonical, for: multi))
        #expect(!multi.accepts(decoded))
        let control = Control(id: "tags", title: "Tags", kind: multi)
        #expect(control.effectiveValue(stored: canonical).state == .invalid)
        #expect(control.effectiveValue(stored: canonical).value == .multiSelect([]))
        let caps = SearchCapabilities(sections: [ControlSection(id: "s", title: "S", controls: [control])])
        if case .string(let stored)? = caps.filterItems(values: ["tags": decoded]).first?.value {
            #expect(stored == "[]")
        } else { Issue.record("Expected canonical multi-select filter") }
    }

    @Test func conditionsMatchOnlyExactOpaqueValues() {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let source = OptionSource.catalog(OptionCatalog(id: "tags"))
        for kind in [
            ControlKind.select(SelectControl(options: source)),
            .multiSelect(MultiSelectControl(options: source, defaultValue: []))
        ] {
            let target = Control(id: "target", title: "Target", kind: kind)
            let dependent = Control(id: "dependent", title: "Dependent",
                                    visibleWhen: [ControlCondition(control: "target", anyOf: [composed])], kind: toggle)
            let caps = SearchCapabilities(sections: [ControlSection(id: "s", title: "S", controls: [target, dependent])])
            let exact: ControlValue, wrongForm: ControlValue
            if case .select = kind {
                exact = .select(composed); wrongForm = .select(decomposed)
            } else {
                exact = .multiSelect([decomposed, composed]); wrongForm = .multiSelect([decomposed])
            }
            #expect(caps.visibleControlIDs(values: ["target": exact]).contains("dependent"))
            #expect(!caps.visibleControlIDs(values: ["target": wrongForm]).contains("dependent"))
            let form = SettingsForm(sections: caps.sections)
            #expect(!form.visibleControlIDs { $0.id == "target" ? wrongForm : $0.kind.defaultValue }.contains("dependent"))
        }
    }
}

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
}

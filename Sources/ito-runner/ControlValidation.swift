import Foundation

public enum ControlLimits {
    public static let formBytes = 262_144
    public static let capabilitiesBytes = 262_144
    public static let optionPageBytes = 131_072
    public static let suggestionsBytes = 16_384
    public static let bodyBytes = 65_536
    public static let sections = 32
    public static let controls = 256
    public static let sectionControls = 64
    public static let conditions = 4
    public static let conditionValues = 16
    public static let inlineOptions = 256
    public static let formOptions = 2048
    public static let defaultValues = 64
    public static let maxSelected = 500
    public static let pageOptions = 100
    public static let suggestions = 20
    public static let loadedOptions = 10_000
    public static let idBytes = 64
    public static let valueBytes = 256
    public static let titleBytes = 256
    public static let labelBytes = 256
    public static let summaryBytes = 1024
    public static let groupBytes = 128
    public static let placeholderBytes = 128
    public static let unitBytes = 32
    public static let textBytes = 4096
    public static let revisionBytes = 64
    public static let queryBytes = 256
    public static let subtitleBytes = 256
}
public struct ControlContractViolation: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Rule: String, Sendable, CaseIterable {
        case signature = "signature"
        case responseTooLarge = "response.too_large"
        case requestInvalid = "request.invalid"
        case countSections = "count.sections"
        case countControls = "count.controls"
        case countSectionControls = "count.section_controls"
        case countConditions = "count.conditions"
        case countConditionValues = "count.condition_values"
        case countOptions = "count.options"
        case countFormOptions = "count.form_options"
        case countDefaultValues = "count.default_values"
        case countPageOptions = "count.page_options"
        case countSuggestions = "count.suggestions"
        case lengthId = "length.id"
        case lengthTitle = "length.title"
        case lengthSummary = "length.summary"
        case lengthLabel = "length.label"
        case lengthGroup = "length.group"
        case lengthPlaceholder = "length.placeholder"
        case lengthUnit = "length.unit"
        case lengthDefault = "length.default"
        case lengthValue = "length.value"
        case lengthRevision = "length.revision"
        case lengthQuery = "length.query"
        case lengthSubtitle = "length.subtitle"
        case lengthBody = "length.body"
        case charsId = "chars.id"
        case charsText = "chars.text"
        case charsValue = "chars.value"
        case duplicateSection = "duplicate.section"
        case duplicateControl = "duplicate.control"
        case duplicateOption = "duplicate.option"
        case duplicateValue = "duplicate.value"
        /// Reserved for SDK validation; hosts preserve and ignore unknown flag bits.
        case flagsUndefined = "flags.undefined"
        case controlBody = "control.body"
        case controlBounds = "control.bounds"
        case controlDefault = "control.default"
        case controlMaxSelected = "control.max_selected"
        case controlContext = "control.context"
        case conditionTarget = "condition.target"
        case conditionValue = "condition.value"
        case pageProgress = "page.progress"
        case pageValues = "page.values"
    }
    public let rule: Rule
    public let id: String?
    public init(_ rule: Rule, id: String? = nil) {
        self.rule = rule
        self.id = id.flatMap { ControlValidation.validID($0) ? $0 : nil }
    }
    public var description: String { rule.rawValue + (id.map { " (\($0))" } ?? "") }
}

/// Stateless validation shared by decoding and host-created requests. Error text never includes values.
enum ControlValidation {
    static func validID(_ s: String) -> Bool {
        (1...ControlLimits.idBytes).contains(s.utf8.count) && s.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
        }
    }
    static func humanCharacters(_ s: String, newline: Bool = false) -> Bool {
        s.unicodeScalars.allSatisfy { (newline && $0.value == 10) || ($0.value >= 32 && !(127...159).contains($0.value)) }
    }
    static func validValue(_ s: String) -> Bool {
        (1...ControlLimits.valueBytes).contains(s.utf8.count) && humanCharacters(s)
    }
    static func require(_ condition: Bool, _ rule: ControlContractViolation.Rule, _ id: String? = nil) throws {
        if !condition { throw ControlContractViolation(rule, id: id) }
    }
    static func identifier(_ s: String) throws {
        try require((1...ControlLimits.idBytes).contains(s.utf8.count), .lengthId)
        try require(validID(s), .charsId)
    }
    static func human(_ s: String, max: Int, rule: ControlContractViolation.Rule, id: String? = nil, newline: Bool = false, empty: Bool = false) throws {
        try require(s.utf8.count <= max && (empty || !s.isEmpty), rule, id)
        try require(humanCharacters(s, newline: newline), .charsText, id)
    }
    static func value(_ s: String, id: String? = nil, rule: ControlContractViolation.Rule = .lengthValue) throws {
        try require((1...ControlLimits.valueBytes).contains(s.utf8.count), rule, id)
        try require(validValue(s), .charsValue, id)
    }
    static func values(_ values: [String], id: String? = nil, rule: ControlContractViolation.Rule = .lengthValue) throws {
        var seen = Set<Data>()
        for v in values {
            try value(v, id: id, rule: rule)
            try require(seen.insert(Data(v.utf8)).inserted, .duplicateValue, id)
        }
    }
    static func options(_ options: [ChoiceOption], id: String? = nil) throws {
        var seen = Set<Data>()
        for option in options {
            try value(option.value, id: id)
            try require(seen.insert(option.identity).inserted, .duplicateOption, id)
            try human(option.label, max: ControlLimits.labelBytes, rule: .lengthLabel, id: id)
            if let group = option.group { try human(group, max: ControlLimits.groupBytes, rule: .lengthGroup, id: id) }
        }
    }
    static func source(_ source: OptionSource, id: String, total: inout Int) throws {
        switch source {
        case .inline(let choices):
            try require((1...ControlLimits.inlineOptions).contains(choices.count), .countOptions, id)
            total += choices.count
            try require(total <= ControlLimits.formOptions, .countFormOptions, id)
            try options(choices, id: id)
        case .catalog(let catalog): try identifier(catalog.id)
        }
    }
    static func control(_ c: Control, search: Bool, optionsTotal: inout Int) throws {
        try identifier(c.id)
        try human(c.title, max: ControlLimits.titleBytes, rule: .lengthTitle, id: c.id)
        if let summary = c.summary { try human(summary, max: ControlLimits.summaryBytes, rule: .lengthSummary, id: c.id, newline: true) }
        try require(c.visibleWhen.count <= ControlLimits.conditions, .countConditions, c.id)
        for condition in c.visibleWhen {
            try identifier(condition.control)
            try require((1...ControlLimits.conditionValues).contains(condition.anyOf.count), .countConditionValues, c.id)
            try values(condition.anyOf, id: c.id)
        }
        switch c.kind {
        case .toggle, .unsupported: break
        case .text(let body):
            try human(body.defaultValue, max: ControlLimits.textBytes, rule: .lengthDefault, id: c.id,
                      newline: body.flags.contains(.multiline), empty: true)
            if let p = body.placeholder { try human(p, max: ControlLimits.placeholderBytes, rule: .lengthPlaceholder, id: c.id) }
        case .secret(let body):
            try require(!search, .controlContext, c.id)
            if let p = body.placeholder { try human(p, max: ControlLimits.placeholderBytes, rule: .lengthPlaceholder, id: c.id) }
        case .select(let body):
            try source(body.options, id: c.id, total: &optionsTotal)
            if let v = body.defaultValue {
                try value(v, id: c.id, rule: .lengthDefault)
                if case .inline(let choices) = body.options { try require(choices.contains { $0.value.utf8.elementsEqual(v.utf8) }, .controlDefault, c.id) }
            }
        case .multiSelect(let body):
            try source(body.options, id: c.id, total: &optionsTotal)
            try require(body.defaultValue.count <= ControlLimits.defaultValues, .countDefaultValues, c.id)
            try values(body.defaultValue, id: c.id, rule: .lengthDefault)
            if let cap = body.maxSelected { try require(cap >= 1 && cap <= UInt32(ControlLimits.maxSelected) && Int(cap) >= body.defaultValue.count, .controlMaxSelected, c.id) }
            if case .inline(let choices) = body.options {
                let known = Set(choices.map(\.identity))
                try require(body.defaultValue.allSatisfy { known.contains(Data($0.utf8)) }, .controlDefault, c.id)
            }
        case .integer(let body):
            try require(body.min <= body.max, .controlBounds, c.id)
            try require(body.defaultValue.map { $0 >= body.min && $0 <= body.max } ?? true, .controlDefault, c.id)
            if let unit = body.unit { try human(unit, max: ControlLimits.unitBytes, rule: .lengthUnit, id: c.id) }
        case .integerRange(let body):
            try require(body.min <= body.max, .controlBounds, c.id)
            try require(c.kind.defaultValue.map(c.kind.accepts) ?? false, .controlDefault, c.id)
            if let unit = body.unit { try human(unit, max: ControlLimits.unitBytes, rule: .lengthUnit, id: c.id) }
        }
    }
    static func document(sections: [ControlSection], sort: Control? = nil, search: Bool = false) throws {
        try require(sections.count <= ControlLimits.sections, .countSections)
        var sectionIDs = Set<String>(), controlIDs = Set<String>(), all: [Control] = []
        var optionsTotal = 0
        func visit(_ c: Control) throws {
            try identifier(c.id)
            try require(controlIDs.insert(c.id).inserted, .duplicateControl, c.id)
            all.append(c)
            try require(all.count <= ControlLimits.controls, .countControls, c.id)
            try control(c, search: search, optionsTotal: &optionsTotal)
        }
        if let sort {
            try visit(sort)
            if case .select(let body) = sort.kind, case .inline = body.options, body.defaultValue != nil, sort.visibleWhen.isEmpty {} else {
                throw ControlContractViolation(.controlContext, id: sort.id)
            }
        }
        for section in sections {
            try identifier(section.id)
            try require(sectionIDs.insert(section.id).inserted, .duplicateSection, section.id)
            try human(section.title, max: ControlLimits.titleBytes, rule: .lengthTitle, id: section.id)
            if let summary = section.summary { try human(summary, max: ControlLimits.summaryBytes, rule: .lengthSummary, id: section.id, newline: true) }
            try require(section.controls.count <= ControlLimits.sectionControls, .countSectionControls, section.id)
            for c in section.controls { try visit(c) }
        }
        let targets = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for c in all {
            for condition in c.visibleWhen {
                guard let target = targets[condition.control], target.id != c.id, target.visibleWhen.isEmpty else {
                    throw ControlContractViolation(.conditionTarget, id: c.id)
                }
                switch target.kind {
                case .toggle: try require(condition.anyOf.allSatisfy { $0 == "true" || $0 == "false" }, .conditionValue, c.id)
                case .select, .multiSelect, .unsupported: break
                default: throw ControlContractViolation(.conditionTarget, id: c.id)
                }
            }
        }
    }
    static func request(_ request: OptionRequest) throws {
        do {
            try identifier(request.catalog)
            try require((1...UInt32(ControlLimits.pageOptions)).contains(request.limit), .requestInvalid)
            switch request.query {
            case .search(let text, _): try require(text.utf8.count <= ControlLimits.queryBytes, .requestInvalid)
            case .values(let items):
                try require(items.count == Int(request.limit), .requestInvalid)
                try values(items)
            }
        } catch { throw ControlContractViolation(.requestInvalid) }
    }
    static func page(_ page: OptionPage, request: OptionRequest) throws {
        try require(page.options.count <= Int(request.limit), .countPageOptions, request.catalog)
        try options(page.options, id: request.catalog)
        switch request.query {
        case .search(_, let offset): try require(page.nextOffset.map { $0 > offset } ?? true, .pageProgress, request.catalog)
        case .values(let values):
            let requested = Set(values.map { Data($0.utf8) })
            try require(page.nextOffset == nil && page.options.allSatisfy { requested.contains($0.identity) }, .pageValues, request.catalog)
        }
        if let revision = page.revision {
            try require((1...ControlLimits.revisionBytes).contains(revision.utf8.count), .lengthRevision, request.catalog)
            try require(revision.utf8.allSatisfy { (33...126).contains($0) }, .charsText, request.catalog)
        }
    }
    static func suggestions(_ suggestions: [SearchSuggestion]) throws {
        try require(suggestions.count <= ControlLimits.suggestions, .countSuggestions)
        for s in suggestions {
            try human(s.query, max: ControlLimits.queryBytes, rule: .lengthQuery)
            if let subtitle = s.subtitle { try human(subtitle, max: ControlLimits.subtitleBytes, rule: .lengthSubtitle) }
        }
    }
}

/// Decodes with prefix limits before allocating elements, then checks cross-field constraints.
enum ControlsDecoder {
    static func settingsForm(_ bytes: [UInt8]) throws -> SettingsForm {
        let form = try ItoPostcardDecoder().decodeControls(SettingsForm.self, from: bytes)
        try ControlValidation.document(sections: form.sections)
        return form
    }
    static func searchCapabilities(_ bytes: [UInt8]) throws -> SearchCapabilities {
        let c = try ItoPostcardDecoder().decodeControls(SearchCapabilities.self, from: bytes)
        try ControlValidation.document(sections: c.sections, sort: c.sort, search: true)
        return c
    }
    static func optionPage(_ bytes: [UInt8], request: OptionRequest) throws -> OptionPage {
        let page = try ItoPostcardDecoder().decodeControls(OptionPage.self, from: bytes, pageLimit: Int(request.limit))
        try ControlValidation.page(page, request: request)
        return page
    }
    static func suggestions(_ bytes: [UInt8]) throws -> [SearchSuggestion] {
        let s = try ItoPostcardDecoder().decodeControls([SearchSuggestion].self, from: bytes)
        try ControlValidation.suggestions(s)
        return s
    }
}

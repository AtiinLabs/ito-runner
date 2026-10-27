// Rich controls v1. Field declaration order is the Postcard wire contract.
import Foundation

public struct SettingsForm: Codable, Equatable, Sendable {
    public var sections: [ControlSection]
    public init(sections: [ControlSection]) {
        self.sections = sections
    }
}

public struct ControlSection: Codable, Equatable, Sendable {
    public struct Flags: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let page = Flags(rawValue: 1 << 0)
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UInt32.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
    public var id: String
    public var title: String
    public var summary: String?
    public var flags: Flags
    public var controls: [Control]
    public init(id: String, title: String, summary: String? = nil, flags: Flags = [], controls: [Control]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.flags = flags
        self.controls = controls
    }
}

public struct ControlCondition: Codable, Equatable, Sendable {
    public var control: String
    public var anyOf: [String]
    public init(control: String, anyOf: [String]) {
        self.control = control
        self.anyOf = anyOf
    }
}

public struct ToggleControl: Codable, Equatable, Sendable {
    public var defaultValue: Bool
    public init(defaultValue: Bool) {
        self.defaultValue = defaultValue
    }
}

public struct TextControl: Codable, Equatable, Sendable {
    public struct Flags: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let url = Flags(rawValue: 1 << 0)
        public static let multiline = Flags(rawValue: 1 << 1)
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UInt32.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
    public var defaultValue: String
    public var placeholder: String?
    public var flags: Flags
    public init(defaultValue: String, placeholder: String? = nil, flags: Flags = []) {
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.flags = flags
    }
}

public struct SecretControl: Codable, Equatable, Sendable {
    public var placeholder: String?
    public init(placeholder: String? = nil) {
        self.placeholder = placeholder
    }
}

public struct SelectControl: Codable, Equatable, Sendable {
    public var options: OptionSource
    public var defaultValue: String?
    public init(options: OptionSource, defaultValue: String? = nil) {
        self.options = options
        self.defaultValue = defaultValue
    }
}

public struct MultiSelectControl: Codable, Equatable, Sendable {
    public var options: OptionSource
    public var defaultValue: [String]
    public var maxSelected: UInt32?
    public init(options: OptionSource, defaultValue: [String], maxSelected: UInt32? = nil) {
        self.options = options
        self.defaultValue = defaultValue
        self.maxSelected = maxSelected
    }
}

public struct IntegerControl: Codable, Equatable, Sendable {
    public var min: Int64
    public var max: Int64
    public var defaultValue: Int64?
    public var unit: String?
    public init(min: Int64, max: Int64, defaultValue: Int64? = nil, unit: String? = nil) {
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.unit = unit
    }
}

public struct IntegerRangeControl: Codable, Equatable, Sendable {
    public var min: Int64
    public var max: Int64
    public var defaultLower: Int64?
    public var defaultUpper: Int64?
    public var unit: String?
    public init(min: Int64, max: Int64, defaultLower: Int64? = nil, defaultUpper: Int64? = nil, unit: String? = nil) {
        self.min = min
        self.max = max
        self.defaultLower = defaultLower
        self.defaultUpper = defaultUpper
        self.unit = unit
    }
}

public struct OptionCatalog: Codable, Equatable, Sendable {
    public struct Flags: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let searchable = Flags(rawValue: 1 << 0)
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UInt32.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
    public var id: String
    public var flags: Flags
    public init(id: String, flags: Flags = []) {
        self.id = id
        self.flags = flags
    }
}

public struct ChoiceOption: Codable, Hashable, Sendable {
    public var value: String
    public var label: String
    public var group: String?
    public init(value: String, label: String, group: String? = nil) {
        self.value = value
        self.label = label
        self.group = group
    }
}

public struct OptionRequest: Codable, Equatable, Sendable {
    public var catalog: String
    public var query: OptionQuery
    public var limit: UInt32
    public init(catalog: String, query: OptionQuery, limit: UInt32) {
        self.catalog = catalog
        self.query = query
        self.limit = limit
    }
}

public struct OptionPage: Codable, Equatable, Sendable {
    public var options: [ChoiceOption]
    public var nextOffset: UInt32?
    public var total: UInt32?
    public var revision: String?
    public init(options: [ChoiceOption], nextOffset: UInt32? = nil, total: UInt32? = nil, revision: String? = nil) {
        self.options = options
        self.nextOffset = nextOffset
        self.total = total
        self.revision = revision
    }
}

public struct SearchCapabilities: Codable, Equatable, Sendable {
    public struct Flags: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let browse = Flags(rawValue: 1 << 0)
        public static let sortWithQuery = Flags(rawValue: 1 << 1)
        public static let filtersWithQuery = Flags(rawValue: 1 << 2)
        public static let suggestions = Flags(rawValue: 1 << 3)
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UInt32.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
    public var flags: Flags
    public var sort: Control?
    public var sections: [ControlSection]
    public init(flags: Flags = [], sort: Control? = nil, sections: [ControlSection]) {
        self.flags = flags
        self.sort = sort
        self.sections = sections
    }
}

public struct SearchSuggestion: Codable, Equatable, Sendable {
    public var query: String
    public var subtitle: String?
    public init(query: String, subtitle: String? = nil) {
        self.query = query
        self.subtitle = subtitle
    }
}

public enum OptionSource: Codable, Equatable, Sendable, PostcardEnumMarker {
    case inline([ChoiceOption])
    case catalog(OptionCatalog)
    enum CodingKeys: Int, CodingKey, PostcardEnumKeys { case inline = 0, catalog = 1 }
}
public enum OptionQuery: Codable, Equatable, Sendable, PostcardEnumMarker {
    case search(text: String, offset: UInt32)
    case values([String])
    enum CodingKeys: Int, CodingKey, PostcardEnumKeys { case search = 0, values = 1 }
}
public enum SettingsSurface: Sendable {
    case form(SettingsForm)
    case legacy(SettingsSchema, formFailure: ItoError?)
}
public enum ControlKind: Equatable, Sendable {
    case toggle(ToggleControl)
    case text(TextControl)
    case secret(SecretControl)
    case select(SelectControl)
    case multiSelect(MultiSelectControl)
    case integer(IntegerControl)
    case integerRange(IntegerRangeControl)
    case unsupported(tag: UInt32)
    public var tag: UInt32 {
        switch self {
        case .toggle: return 0
        case .text: return 1
        case .secret: return 2
        case .select: return 3
        case .multiSelect: return 4
        case .integer: return 5
        case .integerRange: return 6
        case .unsupported(let tag): return tag
        }
    }
    public var wireName: String? {
        switch self {
        case .toggle: return "toggle"
        case .text: return "text"
        case .secret: return "secret"
        case .select: return "select"
        case .multiSelect: return "multi_select"
        case .integer: return "integer"
        case .integerRange: return "integer_range"
        case .unsupported: return nil
        }
    }
}
public struct Control: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String?
    public var flags: UInt32
    public var visibleWhen: [ControlCondition]
    public var kind: ControlKind
    public init(id: String, title: String, summary: String? = nil, flags: UInt32 = 0,
                visibleWhen: [ControlCondition] = [], kind: ControlKind) {
        self.id = id; self.title = title; self.summary = summary; self.flags = flags
        self.visibleWhen = visibleWhen; self.kind = kind
    }
    enum CodingKeys: String, CodingKey { case id, title, summary, flags, visibleWhen, kindTag, kindBody }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        flags = try c.decode(UInt32.self, forKey: .flags)
        visibleWhen = try c.decode([ControlCondition].self, forKey: .visibleWhen)
        let tag = try c.decode(UInt32.self, forKey: .kindTag)
        let body = try c.decode([UInt8].self, forKey: .kindBody)
        guard body.count <= ControlLimits.bodyBytes else { throw ControlContractViolation(.lengthBody, id: id) }
        do {
            let decoder = ItoPostcardDecoder()
            switch tag {
            case 0: kind = .toggle(try decoder.decodeControls(ToggleControl.self, from: body))
            case 1: kind = .text(try decoder.decodeControls(TextControl.self, from: body))
            case 2: kind = .secret(try decoder.decodeControls(SecretControl.self, from: body))
            case 3: kind = .select(try decoder.decodeControls(SelectControl.self, from: body))
            case 4: kind = .multiSelect(try decoder.decodeControls(MultiSelectControl.self, from: body))
            case 5: kind = .integer(try decoder.decodeControls(IntegerControl.self, from: body))
            case 6: kind = .integerRange(try decoder.decodeControls(IntegerRangeControl.self, from: body))
            default: kind = .unsupported(tag: tag)
            }
        } catch let violation as ControlContractViolation { throw violation }
        catch { throw ControlContractViolation(.controlBody, id: id) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(summary, forKey: .summary); try c.encode(flags, forKey: .flags)
        try c.encode(visibleWhen, forKey: .visibleWhen); try c.encode(kind.tag, forKey: .kindTag)
        let encoder = ItoPostcardEncoder()
        let body: [UInt8]
        switch kind {
        case .toggle(let value): body = try encoder.encode(value)
        case .text(let value): body = try encoder.encode(value)
        case .secret(let value): body = try encoder.encode(value)
        case .select(let value): body = try encoder.encode(value)
        case .multiSelect(let value): body = try encoder.encode(value)
        case .integer(let value): body = try encoder.encode(value)
        case .integerRange(let value): body = try encoder.encode(value)
        case .unsupported: throw ItoError.postcardEncodingError("Unsupported control kind")
        }
        try c.encode(body, forKey: .kindBody)
    }
}

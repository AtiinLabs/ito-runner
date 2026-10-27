import Foundation

public enum ControlValue: Hashable, Sendable {
    case toggle(Bool), text(String), select(String?), multiSelect([String]), integer(Int64?)
    case integerRange(lower: Int64?, upper: Int64?)
}

public enum ControlValueCodec {
    public static func canonical(_ value: ControlValue) -> String {
        switch value {
        case .toggle(let value): return value ? "true" : "false"
        case .text(let value): return value
        case .select(let value): return value ?? ""
        case .integer(let value): return value.map(String.init) ?? ""
        case .integerRange(let lower, let upper):
            return "[\(lower.map(String.init) ?? "null"),\(upper.map(String.init) ?? "null")]"
        case .multiSelect(let values): return "[" + values.map(quoted).joined(separator: ",") + "]"
        }
    }
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 0...31:
                let hex = String(scalar.value, radix: 16)
                result += "\\u00" + (hex.count == 1 ? "0" : "") + hex
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    private static func integer(_ text: String) -> Int64? {
        guard let value = Int64(text), String(value) == text else { return nil }
        return value
    }
    public static func decode(_ canonical: String, for kind: ControlKind) -> ControlValue? {
        switch kind {
        case .toggle:
            if canonical == "true" { return .toggle(true) }
            if canonical == "false" { return .toggle(false) }
            return nil
        case .text: return .text(canonical)
        case .select: return .select(canonical.isEmpty ? nil : canonical)
        case .integer:
            if canonical.isEmpty { return .integer(nil) }
            return integer(canonical).map { .integer($0) }
        case .multiSelect:
            // JSON parsing is used only as a recognizer. Re-encoding with our writer rejects every
            // noncanonical escape, whitespace, duplicate, empty item and alternate spelling.
            guard let data = canonical.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String],
                  values.allSatisfy({ !$0.isEmpty }), Set(values).count == values.count,
                  self.canonical(.multiSelect(values)) == canonical else { return nil }
            return .multiSelect(values)
        case .integerRange:
            guard canonical.first == "[", canonical.last == "]" else { return nil }
            let parts = canonical.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let lower = integer(String(parts[0])), upper = integer(String(parts[1]))
            guard (lower != nil || parts[0] == "null"), (upper != nil || parts[1] == "null") else { return nil }
            if let lower, let upper, lower > upper { return nil }
            return .integerRange(lower: lower, upper: upper)
        case .secret, .unsupported: return nil
        }
    }
}

public enum StoredValueState: Equatable, Sendable { case unset, valid, invalid }

extension ControlKind {
    public var defaultValue: ControlValue? {
        switch self {
        case .toggle(let c): return .toggle(c.defaultValue)
        case .text(let c): return .text(c.defaultValue)
        case .select(let c): return .select(c.defaultValue)
        case .multiSelect(let c): return .multiSelect(c.defaultValue)
        case .integer(let c): return .integer(c.defaultValue)
        case .integerRange(let c): return .integerRange(lower: c.defaultLower, upper: c.defaultUpper)
        case .secret, .unsupported: return nil
        }
    }
    public func accepts(_ value: ControlValue) -> Bool {
        switch (self, value) {
        case (.toggle, .toggle): return true
        case (.text(let c), .text(let value)):
            return value.utf8.count <= ControlLimits.textBytes && ControlValidation.humanCharacters(value, newline: c.flags.contains(.multiline))
        case (.select, .select(let value)): return value.map(ControlValidation.validValue) ?? true
        case (.multiSelect(let c), .multiSelect(let values)):
            return values.count <= Int(c.maxSelected ?? UInt32(ControlLimits.maxSelected)) && values.count <= ControlLimits.maxSelected
                && Set(values).count == values.count && values.allSatisfy(ControlValidation.validValue)
        case (.integer(let c), .integer(let value)): return value.map { $0 >= c.min && $0 <= c.max } ?? true
        case (.integerRange(let c), .integerRange(let lower, let upper)):
            return (lower.map { $0 >= c.min && $0 <= c.max } ?? true)
                && (upper.map { $0 >= c.min && $0 <= c.max } ?? true)
                && (lower == nil || upper == nil || lower! <= upper!)
        default: return false
        }
    }
}

extension Control {
    public func effectiveValue(stored: String?) -> (value: ControlValue?, state: StoredValueState) {
        guard let stored else { return (kind.defaultValue, .unset) }
        guard let value = ControlValueCodec.decode(stored, for: kind), kind.accepts(value) else {
            return (kind.defaultValue, .invalid)
        }
        return (value, .valid)
    }
}

private func visibleIDs(_ controls: [Control], value: (Control) -> ControlValue?) -> Set<String> {
    let targets = Dictionary(controls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return Set(controls.filter { control in
        control.visibleWhen.allSatisfy { condition in
            guard let target = targets[condition.control] else { return false }
            if case .unsupported = target.kind { return true }
            switch value(target) {
            case .toggle(let v): return condition.anyOf.contains(v ? "true" : "false")
            case .select(let v): return v.map(condition.anyOf.contains) ?? false
            case .multiSelect(let v): return v.contains(where: condition.anyOf.contains)
            default: return false
            }
        }
    }.map(\.id))
}
extension SettingsForm {
    public var controls: [Control] { sections.flatMap(\.controls) }
    public func visibleControlIDs(effectiveValue: (Control) -> ControlValue?) -> Set<String> {
        visibleIDs(controls, value: effectiveValue)
    }
}
extension SearchCapabilities {
    public var controls: [Control] { (sort.map { [$0] } ?? []) + sections.flatMap(\.controls) }
    public func visibleControlIDs(values: [String: ControlValue]) -> Set<String> {
        visibleIDs(controls) { c in values[c.id].flatMap { c.kind.accepts($0) ? $0 : nil } ?? c.kind.defaultValue }
    }
    func filterItems(values: [String: ControlValue]) -> [FilterItem] {
        let controls = self.controls
        let visible = visibleIDs(controls) { c in
            values[c.id].flatMap { c.kind.accepts($0) ? $0 : nil } ?? c.kind.defaultValue
        }
        return controls.compactMap { control in
            guard let name = control.kind.wireName, name != "secret",
                  let value = visible.contains(control.id)
                    ? (values[control.id].flatMap { control.kind.accepts($0) ? $0 : nil } ?? control.kind.defaultValue)
                    : control.kind.defaultValue else { return nil }
            return FilterItem(type: name, name: control.id, value: .string(ControlValueCodec.canonical(value)))
        }
    }
}

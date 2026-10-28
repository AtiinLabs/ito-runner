import Foundation

/// Represents errors that can occur within the `ito-runner` execution engine.
public enum ItoError: LocalizedError, Equatable {

    /// WebAssembly trap (e.g., division by zero, out of bounds access).
    case wasmTrap(String)

    /// Attempted to read or write memory outside the allocated bounds of the Wasm linear memory.
    case memoryOutOfBounds(offset: Int, length: Int, memorySize: Int)

    /// Failed to decode a Postcard payload.
    case postcardDecodingError(String)

    /// Failed to encode a native Swift object to a Postcard payload.
    case postcardEncodingError(String)

    /// The specific FFI or Host module threw an error
    case hostModuleError(domain: String, message: String)

    /// The plugin's export reported a failure. `reason` is the text the plugin gave
    /// (e.g. "Host error: Add your server URL"), or nil when it gave none; `category` is the kind
    /// of failure, when the plugin says (`.other` otherwise).
    case pluginFailed(function: String, reason: String?, category: PluginErrorCategory = .other)

    /// The plugin imports what this runner doesn't provide (a host function it lacks, or one with
    /// a different signature), so it was built for a newer host. Named as "module.name".
    case requiresNewerHost(missingImports: [String])

    /// The plugin was built for an ABI version (`ito_abi_version`) this runner doesn't support.
    case unsupportedABI(version: Int, supported: ClosedRange<Int>)

    case controlContractViolation(function: String, violation: ControlContractViolation)

    public var isCrash: Bool {
        switch self {
        case .wasmTrap, .memoryOutOfBounds: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .controlContractViolation(let function, let violation):
            return "\(function): invalid controls contract: \(violation)"
        case .wasmTrap(let reason):
            return "Wasm execution trapped: \(reason)"
        case .memoryOutOfBounds(let offset, let length, let memorySize):
            return
                "Wasm memory access out of bounds at offset \(offset) with length \(length) (Memory size: \(memorySize))"
        case .postcardDecodingError(let message):
            return "Failed to decode Wasm memory using Postcard format: \(message)"
        case .postcardEncodingError(let message):
            return "Failed to encode native object to Postcard format: \(message)"
        case .hostModuleError(let domain, let message):
            return "Host module '\(domain)' encountered an error: \(message)"
        case .pluginFailed(let function, let reason, _):
            return reason ?? "The plugin couldn't complete \(function)."
        case .requiresNewerHost(let missingImports):
            return "The plugin needs host imports this version doesn't provide: \(missingImports.joined(separator: ", "))"
        case .unsupportedABI(let version, let supported):
            let versions = supported.count == 1
                ? "ABI \(supported.lowerBound)"
                : "ABI \(supported.lowerBound)–\(supported.upperBound)"
            return "The plugin was built for ABI \(version); this version supports \(versions)."
        }
    }

    public static func == (lhs: ItoError, rhs: ItoError) -> Bool {
        switch (lhs, rhs) {
        case (.controlContractViolation(let lf, let lv), .controlContractViolation(let rf, let rv)):
            return lf == rf && lv == rv
        case (.wasmTrap(let l), .wasmTrap(let r)): return l == r
        case (
            .memoryOutOfBounds(let l1, let l2, let l3), .memoryOutOfBounds(let r1, let r2, let r3)
        ):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.postcardDecodingError(let l), .postcardDecodingError(let r)): return l == r
        case (.postcardEncodingError(let l), .postcardEncodingError(let r)): return l == r
        case (.hostModuleError(let l1, let l2), .hostModuleError(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.pluginFailed(let l1, let l2, let l3), .pluginFailed(let r1, let r2, let r3)):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.requiresNewerHost(let l), .requiresNewerHost(let r)): return l == r
        case (.unsupportedABI(let l1, let l2), .unsupportedABI(let r1, let r2)):
            return l1 == r1 && l2 == r2
        default: return false
        }
    }
}

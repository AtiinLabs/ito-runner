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

    /// Host admission authority, never a guest-reported source error.
    case networkPolicy(HostNetworkPolicyOutcome)

    /// Host work the plugin call was waiting on outlived the runner's watchdog deadline
    /// (`HostCallTimeouts`). The plugin saw a failed request and unwound; this is not a server
    /// error the plugin reported, and not a policy refusal.
    case hostCallTimedOut(HostCallKind)

    /// Synchronous loading cannot replace the memory of an executing export. Use a fresh runner
    /// for work that overlaps another export.
    case reloadDuringActiveExport

    /// The call was queued before the plugin was loaded again, so its context and plugin are
    /// gone. It never ran, and it is not a user cancellation.
    case pluginReloaded

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

    /// The plugin's response broke the data contract, as the runner found after decoding it or as
    /// the plugin reported itself (error category `contractViolation`, from any export).
    /// `violation.rule` names the rule for diagnostics; the description never contains it, since
    /// hosts show their own text.
    case catalogContractViolation(function: String, violation: CatalogContractViolation)

    /// The plugin's chapter editions broke the contract of `get_chapter_editions`, as the runner
    /// found in a request or across the pages of a traversal, or as the plugin reported itself.
    /// Chapter rules arrive as `catalogContractViolation`. `violation.rule` is for diagnostics;
    /// the description never contains it.
    case chapterEditionsViolation(function: String, violation: ChapterEditionsViolation)

    public var isCrash: Bool {
        switch self {
        case .wasmTrap, .memoryOutOfBounds: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .reloadDuringActiveExport:
            return "Cannot reload a plugin while an export is active."
        case .pluginReloaded:
            return "The plugin was reloaded before the call could run."
        case .networkPolicy:
            // Intentionally excludes source/account identifiers and grant material. Hosts localize.
            return "Network access is restricted by host policy."
        case .hostCallTimedOut(.net):
            return "A network request took too long to finish."
        case .hostCallTimedOut(.webview):
            return "A web page took too long to respond."
        case .controlContractViolation(let function, let violation):
            return "\(function): invalid controls contract: \(violation)"
        case .catalogContractViolation(let function, _), .chapterEditionsViolation(let function, _):
            // The rule code stays out of the text: it is for diagnostics, not for users.
            return "\(function): the plugin's response broke the data contract."
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
        case (.reloadDuringActiveExport, .reloadDuringActiveExport): return true
        case (.pluginReloaded, .pluginReloaded): return true
        case (.networkPolicy(let l), .networkPolicy(let r)): return l == r
        case (.hostCallTimedOut(let l), .hostCallTimedOut(let r)): return l == r
        case (.controlContractViolation(let lf, let lv), .controlContractViolation(let rf, let rv)):
            return lf == rf && lv == rv
        case (.catalogContractViolation(let lf, let lv), .catalogContractViolation(let rf, let rv)):
            return lf == rf && lv == rv
        case (.chapterEditionsViolation(let lf, let lv), .chapterEditionsViolation(let rf, let rv)):
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

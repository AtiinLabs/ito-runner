import Foundation

/// Represents errors that can occur within the `ito-runner` execution engine.
public enum ItoError: LocalizedError, Equatable {

    /// WebAssembly trap (e.g., division by zero, out of bounds access).
    case wasmTrap(String)

    /// Attempted to read or write memory outside the allocated bounds of the Wasm linear memory.
    case memoryOutOfBounds(offset: Int, length: Int, memorySize: Int)

    /// An invalid descriptor ID was passed from Wasm to Swift.
    case invalidDescriptor(id: UInt32)

    /// Failed to decode a Postcard payload.
    case postcardDecodingError(String)

    /// Failed to encode a native Swift object to a Postcard payload.
    case postcardEncodingError(String)

    /// The specific FFI or Host module threw an error
    case hostModuleError(domain: String, message: String)

    /// The plugin's export reported a failure. `reason` is the text the plugin gave
    /// (e.g. "Host error: Add your server URL"), or nil when it gave none.
    case pluginFailed(function: String, reason: String?)

    public var errorDescription: String? {
        switch self {
        case .wasmTrap(let reason):
            return "Wasm execution trapped: \(reason)"
        case .memoryOutOfBounds(let offset, let length, let memorySize):
            return
                "Wasm memory access out of bounds at offset \(offset) with length \(length) (Memory size: \(memorySize))"
        case .invalidDescriptor(let id):
            return "Wasm plugin provided an invalid resource descriptor ID: \(id)"
        case .postcardDecodingError(let message):
            return "Failed to decode Wasm memory using Postcard format: \(message)"
        case .postcardEncodingError(let message):
            return "Failed to encode native object to Postcard format: \(message)"
        case .hostModuleError(let domain, let message):
            return "Host module '\(domain)' encountered an error: \(message)"
        case .pluginFailed(let function, let reason):
            return reason ?? "The plugin couldn't complete \(function)."
        }
    }

    public static func == (lhs: ItoError, rhs: ItoError) -> Bool {
        switch (lhs, rhs) {
        case (.wasmTrap(let l), .wasmTrap(let r)): return l == r
        case (
            .memoryOutOfBounds(let l1, let l2, let l3), .memoryOutOfBounds(let r1, let r2, let r3)
        ):
            return l1 == r1 && l2 == r2 && l3 == r3
        case (.invalidDescriptor(let l), .invalidDescriptor(let r)): return l == r
        case (.postcardDecodingError(let l), .postcardDecodingError(let r)): return l == r
        case (.postcardEncodingError(let l), .postcardEncodingError(let r)): return l == r
        case (.hostModuleError(let l1, let l2), .hostModuleError(let r1, let r2)):
            return l1 == r1 && l2 == r2
        case (.pluginFailed(let l1, let l2), .pluginFailed(let r1, let r2)):
            return l1 == r1 && l2 == r2
        default: return false
        }
    }
}

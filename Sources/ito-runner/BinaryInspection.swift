import Foundation
import WasmParser

/// What a plugin's WebAssembly module declares, read without instantiating it.
public struct PluginBinaryInterface: Sendable, Equatable {
    /// The constant `ito_abi_version` returns, or 1 when the module doesn't export it.
    public let abiVersion: Int
    /// Every imported item as "module.name", sorted and without duplicates.
    public let imports: [String]
    /// The raw constant `ito_supported_kinds` returns, bit by `MediaKind.wireValue`. Nil below
    /// ABI 2, which ignores the export, and when the module doesn't export it as a defined
    /// `() -> i32` function returning a constant.
    public let kindsMask: UInt32?
    /// Whether the module has a start section. Instantiating such a module runs plugin code before
    /// the host has called any export, so no host runs one.
    public let hasStartSection: Bool
    /// The constant `ito_error_version` returns, or 1 when the module doesn't export it: the report
    /// format the host reads failures in.
    public let errorProtocolVersion: UInt32

    /// The kinds `kindsMask` names, in `MediaKind.allCases` order. Nil when there is no mask, or
    /// it names no kind or one this runner doesn't know.
    public var kinds: [MediaKind]? {
        guard let kindsMask else { return nil }
        let known = MediaKind.allCases.reduce(UInt32(0)) { $0 | 1 << UInt32($1.wireValue) }
        guard kindsMask != 0, kindsMask & ~known == 0 else { return nil }
        return MediaKind.allCases.filter { kindsMask & 1 << UInt32($0.wireValue) != 0 }
    }

    public init(
        abiVersion: Int, imports: [String], kindsMask: UInt32?, hasStartSection: Bool = false,
        errorProtocolVersion: UInt32 = 1
    ) {
        self.abiVersion = abiVersion
        self.imports = imports
        self.kindsMask = kindsMask
        self.hasStartSection = hasStartSection
        self.errorProtocolVersion = errorProtocolVersion
    }

    public init(
        abiVersion: Int, imports: [String], kinds: [MediaKind]?, hasStartSection: Bool = false,
        errorProtocolVersion: UInt32 = 1
    ) {
        self.init(
            abiVersion: abiVersion, imports: imports,
            kindsMask: kinds.map { $0.reduce(UInt32(0)) { $0 | 1 << UInt32($1.wireValue) } },
            hasStartSection: hasStartSection, errorProtocolVersion: errorProtocolVersion)
    }
}

/// Whether this runner can run a plugin binary, and if not, which side has to change.
public enum PluginBinaryCompatibility: Sendable, Equatable {
    case compatible
    /// Built for an older ABI than the runner supports: the plugin needs an update.
    case pluginTooOld(abi: Int)
    /// Built for a newer ABI than the runner supports: the host needs an update.
    case pluginTooNew(abi: Int)
    /// Imports host functions this runner doesn't provide: the host needs an update.
    case missingImports([String])
    /// A module no host runs: it has a start section, or an ABI 2 or later module without a usable
    /// `ito_supported_kinds`.
    case invalid
}

extension ItoRunner {
    /// Reads a plugin's ABI, imports, kinds mask and error-report version from its module bytes.
    /// The module is parsed, never instantiated, so no plugin code runs.
    ///
    /// An absent `ito_abi_version` means ABI 1. `ito_abi_version` must be a function the module
    /// defines, typed `() -> i32`, whose body is a single `i32.const`; anything else throws, as
    /// does a module that doesn't parse. `ito_supported_kinds` is read for ABI 2 and later, and
    /// never throws: the mask is whatever constant a defined `() -> i32` function returns, and nil
    /// when the export is missing, imported, mistyped or not a constant. An absent
    /// `ito_error_version` means version 1; otherwise it must be a defined `() -> i32` function
    /// whose body is a single positive `i32.const`, and any other export of that name, including
    /// one that isn't a function, throws. A start section is reported in `hasStartSection` rather
    /// than thrown, so a caller can still tell which ABI the file was built for. Nothing here
    /// depends on the range of ABIs this runner supports.
    public static func inspectBinary(_ wasm: [UInt8]) throws -> PluginBinaryInterface {
        var imports = Set<String>()
        var importedFunctionTypes: [UInt32] = []
        var definedFunctionTypes: [UInt32] = []
        var isNullaryI32: [Bool] = []  // by type index: is it `() -> i32`
        var abiFunction: UInt32?
        var kindsFunction: UInt32?
        var errorFunction: UInt32?
        var abiBody: Code?
        var kindsBody: Code?
        var errorBody: Code?
        var hasStartSection = false

        do {
            var parser = Parser(bytes: wasm, limits: parsingLimits)
            while let payload = try parser.parseNext() {
                switch payload {
                case .typeSection(let types):
                    isNullaryI32 = types.map { $0.parameters.isEmpty && $0.results.count == 1 && $0.results[0] == .i32 }
                case .importSection(let section):
                    for item in section {
                        imports.insert("\(item.module).\(item.name)")
                        if case .function(let typeIndex) = item.descriptor { importedFunctionTypes.append(typeIndex) }
                    }
                case .functionSection(let typeIndices):
                    definedFunctionTypes = typeIndices
                case .exportSection(let section):
                    for item in section {
                        guard case .function(let index) = item.descriptor else {
                            // A version that isn't a function can't be read; defaulting to 1
                            // would silently downgrade the failure protocol.
                            if item.name == errorExportName {
                                throw ItoError.wasmTrap("\(errorExportName) must be () -> i32")
                            }
                            continue
                        }
                        switch item.name {
                        case abiExportName: abiFunction = index
                        case kindsExportName: kindsFunction = index
                        case errorExportName: errorFunction = index
                        default: break
                        }
                    }
                case .codeSection(let bodies):
                    for (offset, body) in bodies.enumerated() {
                        // Function indices count imports first.
                        let index = importedFunctionTypes.count + offset
                        if abiFunction.map({ Int($0) }) == index { abiBody = body }
                        if kindsFunction.map({ Int($0) }) == index { kindsBody = body }
                        if errorFunction.map({ Int($0) }) == index { errorBody = body }
                    }
                case .startSection:
                    hasStartSection = true
                default:
                    break
                }
            }

            /// Whether function `index` is typed `() -> i32`.
            func hasConstantSignature(_ index: UInt32) -> Bool {
                let position = Int(index)
                let definedPosition = position - importedFunctionTypes.count
                let typeIndex: UInt32
                if importedFunctionTypes.indices.contains(position) {
                    typeIndex = importedFunctionTypes[position]
                } else if definedFunctionTypes.indices.contains(definedPosition) {
                    typeIndex = definedFunctionTypes[definedPosition]
                } else {
                    return false
                }
                return isNullaryI32.indices.contains(Int(typeIndex)) && isNullaryI32[Int(typeIndex)]
            }

            var abi = 1
            if let function = abiFunction {
                guard let body = abiBody else {
                    throw ItoError.wasmTrap("\(abiExportName) must be defined in the module, not imported")
                }
                guard hasConstantSignature(function) else {
                    throw ItoError.wasmTrap("\(abiExportName) must be () -> i32")
                }
                abi = Int(try constantResult(of: body, export: abiExportName))
            }

            // The mask is not judged here: whether this runner can use it is `compatibility`'s call,
            // so a plugin newer than the runner is still reported by its ABI.
            var kindsMask: UInt32?
            if abi >= 2, let function = kindsFunction, let body = kindsBody, hasConstantSignature(function) {
                kindsMask = try? constantResult(of: body, export: kindsExportName)
            }

            // Read statically, like the ABI, so loading never calls a plugin export to learn it.
            var errorVersion: UInt32 = 1
            if let function = errorFunction {
                guard let body = errorBody else {
                    throw ItoError.wasmTrap("\(errorExportName) must be defined in the module, not imported")
                }
                guard hasConstantSignature(function) else {
                    throw ItoError.wasmTrap("\(errorExportName) must be () -> i32")
                }
                errorVersion = try constantResult(of: body, export: errorExportName)
                guard errorVersion > 0, errorVersion <= UInt32(Int32.max) else {
                    throw ItoError.wasmTrap("\(errorExportName) must return a positive version")
                }
            }

            return PluginBinaryInterface(
                abiVersion: abi, imports: imports.sorted(), kindsMask: kindsMask, hasStartSection: hasStartSection,
                errorProtocolVersion: errorVersion)
        } catch let error as ItoError {
            throw error
        } catch {
            throw ItoError.wasmTrap("Invalid WebAssembly module: \(error)")
        }
    }

    /// Reads a packaged `.ito` bundle without loading it: its manifest, and the interface of its
    /// module. The interface is nil whenever the module can't be read: it is missing, too large,
    /// damaged inside the archive, or not a module this runner can inspect. Only an archive that
    /// can't be opened, or a manifest that is missing, too large or undecodable, throws.
    public static func inspectBundle(at url: URL) throws -> (manifest: PluginManifest, binary: PluginBinaryInterface?) {
        let bundle = try PluginBundle(at: url)
        guard let manifest = try bundle.manifest() else {
            throw ItoError.wasmTrap("Archive did not contain a manifest file.")
        }
        let binary = (try? bundle.wasm()).flatMap { try? inspectBinary($0) }
        return (manifest, binary)
    }

    /// Bounds the locals a module may declare, which parsing expands into arrays. Real plugins
    /// declare at most about a hundred per function and several thousand in total, so these leave wide
    /// headroom while a hostile module can't make parsing allocate gigabytes. Inspection and
    /// loading use the same limits, so a module that inspects as loadable also parses on load.
    static let parsingLimits = ParsingLimits(maxFunctionLocals: 10_000, maxTotalLocals: 250_000)

    /// Whether this runner can run a plugin with `binary`: a start section is refused, then its ABI
    /// is compared with `supported`, then its kinds and imports are checked. An ABI 2 or later
    /// plugin must name at least one kind this runner knows, and no other, as `loadPlugin`
    /// requires. Imports are checked by name against the host functions this runner provides, as
    /// `unsupportedImports` does; signatures are only compared when the plugin is loaded.
    public static func compatibility(
        of binary: PluginBinaryInterface,
        supported: ClosedRange<Int> = supportedABIVersions
    ) -> PluginBinaryCompatibility {
        if binary.hasStartSection { return .invalid }
        if binary.abiVersion < supported.lowerBound { return .pluginTooOld(abi: binary.abiVersion) }
        if binary.abiVersion > supported.upperBound { return .pluginTooNew(abi: binary.abiVersion) }
        if binary.abiVersion >= 2 && binary.kinds == nil { return .invalid }
        let missing = unsupportedImports(binary.imports)
        return missing.isEmpty ? .compatible : .missingImports(missing)
    }

    private static let abiExportName = "ito_abi_version"
    private static let kindsExportName = "ito_supported_kinds"
    private static let errorExportName = "ito_error_version"

    /// The value of a function whose body is a single `i32.const`, as the SDK's exports are.
    private static func constantResult(of body: Code, export: String) throws -> UInt32 {
        var visitor = ConstantBodyVisitor()
        do {
            try body.parseExpression(visitor: &visitor)
        } catch is ConstantBodyVisitor.TooLong {
            throw ItoError.wasmTrap("\(export) must return a constant")
        } catch {
            throw ItoError.wasmTrap("Invalid function body for \(export): \(error)")
        }
        guard visitor.instructions.count == 2,
              case .i32Const(let value) = visitor.instructions[0],
              visitor.instructions[1] == .end else {
            throw ItoError.wasmTrap("\(export) must return a constant")
        }
        return UInt32(bitPattern: value)
    }
}

/// Collects a function body's instructions, giving up past what a constant needs, so a large
/// non-constant body is rejected without being read in full.
private struct ConstantBodyVisitor: AnyInstructionVisitor {
    struct TooLong: Error {}

    var binaryOffset = 0
    var instructions: [Instruction] = []

    mutating func visit(_ instruction: Instruction) throws {
        guard instructions.count < 2 else { throw TooLong() }
        instructions.append(instruction)
    }
}

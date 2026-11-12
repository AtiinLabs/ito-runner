import OSLog
import Foundation
import WasmKit

/// The main execution engine for ito-runner.
/// It wraps WasmKit to load, instantiate, and execute WebAssembly plugins.
public actor ItoRunner {

    /// The running WasmKit Instance. We hold onto it so we can execute exports later.
    private var instance: Instance?

    /// The memory space shared by the Wasm plugin and swift.
    private var memory: Memory?

    /// The ABI the loaded plugin was built for (`ito_abi_version`); 0 until a plugin is loaded.
    public private(set) var abiVersion = 0
    /// The kinds the loaded plugin serves (`ito_supported_kinds`).
    public private(set) var supportedKinds: [MediaKind] = []

    /// Decodes the payloads that carry no chapters (settings, error reports, image requests).
    private let postcardDecoder = ItoPostcardDecoder(abiVersion: sharedLayoutABIVersion)

    private enum CapabilitiesEntry {
        case available(SearchCapabilities), absent, failed(ItoError)
    }
    private var capabilitiesByKind: [Int32: CapabilitiesEntry] = [:]

    /// The FFI Bridge that connects Host Modules to Wasm. Created upon plugin load.
    var bridge: WasmBridge?

    public var netModule: NetModule?
    public var htmlModule: HtmlModule?
    public var stdModule: StdModule?
    public var defaultsModule: DefaultsModule?
    public var envModule: EnvModule?
    public var webviewModule: WebviewModule?

    let executionQueue = DispatchQueue(label: "moe.itoapp.runner.execution")
    // Loading is synchronous. Refuse a reload while Wasm is executing rather than replacing
    // its memory underneath it or blocking an actor that host work may need.
    private final class InvocationState: @unchecked Sendable {
        let lock = NSLock()
        // Written only by actor-isolated loading under lock; queue reads hold the same lock.
        var generation = UUID()
    }
    private let invocationState = InvocationState()

    /// How long host work (network, web view) may block a plugin call. Applies to plugins loaded
    /// after it is set.
    public private(set) var hostCallTimeouts = HostCallTimeouts()

    /// Runs one job on the runner's queue, one at a time. Cancelling the caller's task skips the job
    /// if it hasn't started, and cancels host work it is waiting on if it has. Of a host policy
    /// refusal and a cancellation, whichever happened first is the outcome: a refusal recorded
    /// first throws `networkPolicy`, a cancellation first throws `CancellationError`. Either way
    /// it beats whatever the plugin made of the failed host call. A job queued before a reload
    /// throws `pluginReloaded` without running; so does one bound to a plugin generation
    /// (`boundTo`) that a reload has replaced, whenever it was queued.
    func performSerialized<T: Sendable>(
        context: NetworkOperationContext, boundTo boundGeneration: UUID? = nil, _ operation: @escaping () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let token = CallToken(context: context)
        // Read on the actor: the queue never touches runner state after resuming the caller.
        let bridge = self.bridge
        let state = invocationState
        let generation = boundGeneration ?? state.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executionQueue.async {
                    state.lock.lock()
                    let result: Result<T, any Error>
                    if token.isCancelled {
                        result = .failure(CancellationError())
                    } else if generation != state.generation {
                        result = .failure(ItoError.pluginReloaded)
                    } else {
                        bridge?.clearOperationState()
                        bridge?.activeCallToken = token
                        let guestResult = Result { try operation() }
                        bridge?.activeCallToken = nil
                        bridge?.clearOperationState()
                        if let outcome = token.policyOutcome {
                            result = .failure(ItoError.networkPolicy(outcome))
                        } else if token.isCancelled {
                            result = .failure(CancellationError())
                        } else {
                            result = guestResult
                        }
                    }
                    state.lock.unlock()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Initializes a new runner instance.
    public init() {}

    public func setNetModule(_ module: NetModule) { self.netModule = module }
    public func setHtmlModule(_ module: HtmlModule) { self.htmlModule = module }
    public func setStdModule(_ module: StdModule) { self.stdModule = module }
    public func setDefaultsModule(_ module: DefaultsModule) { self.defaultsModule = module }
    public func setEnvModule(_ module: EnvModule) { self.envModule = module }
    public func setWebviewModule(_ module: WebviewModule) { self.webviewModule = module }

    /// Sets how long host work may block a plugin call, for plugins loaded afterwards.
    public func setHostCallTimeouts(_ timeouts: HostCallTimeouts) {
        hostCallTimeouts = timeouts
    }

    /// Loads a `.wasm` file, sets up the host environment (FFI), and instantiates the plugin.
    ///
    /// - Parameter url: The file URL to the `.wasm` binary.
    /// - Throws: An `ItoError` if loading or instantiation fails.
    public func loadPlugin(from url: URL) throws {
        let wasmBytes = try Data(contentsOf: url)
        try loadPlugin(fromBytes: [UInt8](wasmBytes))
    }

    /// The ABI versions (`ito_abi_version`) of plugins this runner can run: ABI 3 only. A plugin
    /// without the export, or with an older or newer version, is refused before anything of it is
    /// decoded or instantiated.
    public static let supportedABIVersions: ClosedRange<Int> = 3...3

    /// The first `ito_error_version` that reports failures with an explicit category, which every
    /// plugin this runner loads must declare.
    static let minimumErrorProtocolVersion: UInt32 = 2

    /// The host functions this runner provides, by module ("ito:core/net") and name.
    public static let supportedImports: [String: Set<String>] = WasmBridge()
        .buildImportTable(store: Store(engine: Engine()))
        .mapValues { Set($0.keys) }

    /// The entries of `imports` ("module.name", as a plugin's manifest lists them) this runner
    /// doesn't provide. Lets a host refuse a plugin before downloading it.
    public static func unsupportedImports(_ imports: [String]) -> [String] {
        imports.filter { entry in
            guard let dot = entry.lastIndex(of: ".") else { return true }
            let module = String(entry[..<dot])
            let name = String(entry[entry.index(after: dot)...])
            return supportedImports[module]?.contains(name) != true
        }
    }

    /// Loads a plugin directly from a WebAssembly byte array. A plugin that imports host functions
    /// this runner lacks, has a start section, was built for an unsupported ABI, or declares no
    /// usable kinds or an old error-report version is refused before anything of it is
    /// instantiated, so none of its code runs. A module that passes those
    /// checks throws `reloadDuringActiveExport` instead of replacing executing Wasm memory. A
    /// successful reload makes queued calls from the previous generation throw `pluginReloaded`.
    /// Use a fresh runner for a new source/account session or independent simultaneous
    /// image/download work.
    public func loadPlugin(fromBytes wasmBytes: [UInt8]) throws {
        do {
            // 1. Read what the module declares without instantiating it.
            let binary = try Self.inspectBinary(wasmBytes)
            guard !binary.hasStartSection else {
                throw ItoError.wasmTrap("The plugin has a start section; modules must do their work only in exports.")
            }
            guard Self.supportedABIVersions.contains(binary.abiVersion) else {
                throw ItoError.unsupportedABI(version: binary.abiVersion, supported: Self.supportedABIVersions)
            }
            // The same verdicts `compatibility(of:)` gives: without a constant naming known kinds,
            // calling the export after instantiation would run plugin code.
            guard binary.kinds != nil else {
                throw ItoError.wasmTrap(
                    "ito_supported_kinds must be a defined () -> i32 returning a constant that names kinds this host knows."
                )
            }
            guard binary.errorProtocolVersion >= Self.minimumErrorProtocolVersion else {
                throw ItoError.wasmTrap(
                    "ito_error_version must be at least \(Self.minimumErrorProtocolVersion): the plugin reports failures in a format this host no longer reads."
                )
            }

            // 2. Initialize a new Wasm Engine & Store
            let engine = Engine()
            let store = Store(engine: engine)

            // 3. Parse the Wasm Module
            let module = try parseWasm(bytes: wasmBytes, limits: Self.parsingLimits)

            // 4. Setup Imports
            let bridge = WasmBridge()
            bridge.netModule = self.netModule
            bridge.htmlModule = self.htmlModule
            bridge.stdModule = self.stdModule
            bridge.defaultsModule = self.defaultsModule
            bridge.envModule = self.envModule
            bridge.webviewModule = self.webviewModule
            bridge.timeouts = self.hostCallTimeouts
            let importTable = bridge.buildImportTable(store: store)

            // Instantiating would fail on the first missing import with an error that can't be
            // told apart from a crash; name every one that isn't a host function of that type.
            let missingImports = Set(module.imports.filter { item in
                guard case .function(let typeIndex) = item.descriptor,
                      let hostFunction = importTable[item.module]?[item.name],
                      module.types.indices.contains(Int(typeIndex)) else { return true }
                return module.types[Int(typeIndex)] != hostFunction.type
            }.map { "\($0.module).\($0.name)" })
            guard missingImports.isEmpty else {
                throw ItoError.requiresNewerHost(missingImports: missingImports.sorted())
            }
            let imports = WasmBridge.imports(from: importTable)

            // Refusals above report what is wrong with the module, whether or not an export is
            // running. From here on the loaded plugin is replaced, so no export may be executing.
            guard invocationState.lock.try() else { throw ItoError.reloadDuringActiveExport }
            defer { invocationState.lock.unlock() }

            // 5. Instantiate the plugin, and keep it only if its exports report what the static
            // read found and it exports its memory. Nothing of a previously loaded plugin is
            // touched until then. The equality checks below guard the static reader's mapping of
            // function indices to code bodies: a reader that attributed a constant to the wrong
            // function would disagree with the instance here instead of passing the ABI gate.
            let instance = try module.instantiate(store: store, imports: imports)
            let abi = try Self.abiVersion(of: instance)
            guard abi == binary.abiVersion else {
                throw ItoError.wasmTrap("ito_abi_version returned \(abi), not the constant it was read as (\(binary.abiVersion)).")
            }
            guard case .memory(let memory)? = instance.exports["memory"] else {
                throw ItoError.wasmTrap("Plugin did not export linear 'memory'.")
            }
            let kinds = try Self.supportedKinds(of: instance)
            guard binary.kinds == kinds else {
                throw ItoError.wasmTrap("ito_supported_kinds returned other kinds than the constant it was read as.")
            }

            // Clear any lingering state from previous runs
            bridge.htmlModule?.clear()
            self.instance = instance
            self.bridge = bridge
            self.memory = memory
            self.abiVersion = abi
            self.supportedKinds = kinds
            self.capabilitiesByKind.removeAll()
            invocationState.generation = UUID()

        } catch let error as ItoError {
            throw error
        } catch {
            throw ItoError.wasmTrap("Failed to load Wasm plugin: \(error.localizedDescription)")
        }
    }

    /// The ABI version `instance` was built for: its `ito_abi_version` export.
    private static func abiVersion(of instance: Instance) throws -> Int {
        guard case .function(let function)? = instance.exports["ito_abi_version"] else {
            throw ItoError.wasmTrap("ito_abi_version is not exported as a function.")
        }
        guard case .i32(let version)? = try function([]).first else {
            throw ItoError.wasmTrap("ito_abi_version must return an i32")
        }
        return Int(version)
    }

    /// The kinds `instance` serves: its `ito_supported_kinds` mask.
    private static func supportedKinds(of instance: Instance) throws -> [MediaKind] {
        guard case .function(let function)? = instance.exports["ito_supported_kinds"],
              function.type.parameters.isEmpty,
              function.type.results == [.i32],
              case .i32(let mask)? = try function([]).first else {
            throw ItoError.wasmTrap("ito_supported_kinds must be () -> i32")
        }
        let known = MediaKind.allCases.reduce(UInt32(0)) { $0 | 1 << UInt32($1.wireValue) }
        guard mask != 0, mask & ~known == 0 else {
            throw ItoError.wasmTrap("ito_supported_kinds must name the kinds this host knows")
        }
        return MediaKind.allCases.filter { mask & 1 << UInt32($0.wireValue) != 0 }
    }

    /// Loads a packaged `.ito` bundle, extracting the wasm logic and returning the manifest, which
    /// is nil when the bundle has none. Throws when the module can't be read, as loading needs it.
    public func loadBundle(from url: URL) throws -> PluginManifest? {
        let bundle = try PluginBundle(at: url)
        let manifest = try bundle.manifest()
        try loadPlugin(fromBytes: try bundle.wasm())
        return manifest
    }

    /// Statically extracts the manifest and optional icon from an `.ito` bundle without loading the Wasm module.
    public static func extractPluginInfo(from url: URL) throws -> (manifest: PluginManifest, icon: Data?) {
        let bundle = try PluginBundle(at: url)
        guard let manifest = try bundle.manifest() else {
            throw ItoError.wasmTrap("Archive did not contain a manifest file.")
        }
        return (manifest, bundle.icon())
    }

    // MARK: - Memory Utilities

    /// Reads a slice of bytes from the Wasm linear memory.
    /// - Parameters:
    ///   - offset: The starting byte offset in Wasm memory.
    ///   - length: The number of bytes to read.
    /// - Returns: An array of bytes.
    /// - Throws: `ItoError.memoryOutOfBounds` if the requested range is outside memory bounds.
    func readMemory(offset: Int, length: Int) throws -> [UInt8] {
        guard let memory = memory else {
            throw ItoError.wasmTrap("Memory is not initialized.")
        }

        let memData = memory.data
        guard offset >= 0, length >= 0, offset + length <= memData.count else {
            throw ItoError.memoryOutOfBounds(
                offset: offset, length: length, memorySize: memData.count)
        }

        return Array(memData[offset..<(offset + length)])
    }

    /// Writes a slice of bytes into the Wasm linear memory.
    /// Note: The plugin is responsible for `alloc`ating this memory first and providing a safe offset!
    /// - Parameters:
    ///   - offset: The starting byte offset in Wasm memory.
    ///   - bytes: The data to write.
    /// - Throws: `ItoError.memoryOutOfBounds` if the requested range is outside memory bounds.
    func writeMemory(offset: Int, bytes: [UInt8]) throws {
        try writeMemoryBytes(offset: offset, bytes: bytes)
    }

    private func writeMemoryBytes<Bytes: Collection>(offset: Int, bytes: Bytes) throws
    where Bytes.Element == UInt8 {
        guard let memory = memory else {
            throw ItoError.wasmTrap("Memory is not initialized.")
        }

        let memorySize = memory.data.count
        let length = bytes.count

        guard offset >= 0, offset <= memorySize, length <= memorySize - offset else {
            throw ItoError.memoryOutOfBounds(
                offset: offset, length: length, memorySize: memorySize)
        }

        // Write the bytes using GuestMemory API
        memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: length) { buffer in
            buffer.copyBytes(from: bytes)
        }
    }

    /// Execute a function exported by the Wasm module.
    ///
    /// - Parameters:
    ///   - name: The name of the exported function (e.g., "get_manga_list")
    ///   - args: Wasm primitive arguments (i32, i64, f32, f64)
    /// - Returns: An array of resulting Wasm primitive values
    /// - Throws: `ItoError` on execution failure or missing export. Errors raised by host modules
    ///   during the call (e.g. `hostModuleError`) are rethrown as they are.
    func executeExport(_ name: String, args: [Value] = []) throws -> [Value] {
        guard let instance = instance else {
            throw ItoError.wasmTrap("Instance is not initialized.")
        }

        guard let exportedItem = instance.exports[name],
            case .function(let function) = exportedItem
        else {
            throw ItoError.wasmTrap("Function '\(name)' not exported by plugin.")
        }

        do {
            return try function(args)
        } catch let error as ItoError {
            throw error
        } catch {
            throw ItoError.wasmTrap("Execution of '\(name)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Export calls

    /// An argument for a plugin export. Byte arguments are copied into plugin memory for the call.
    private enum ExportArgument {
        case bytes([UInt8])
        case int(Int32)
        case flag(Bool)
    }

    private func isExported(_ name: String) -> Bool {
        instance?.exports[name] != nil
    }

    /// A byte budget on a response, checked against its declared length before any of it is read
    /// from plugin memory, and the error a response over the budget throws: a controls violation
    /// for the rich-controls exports, a catalog violation for the catalog exports.
    private enum ResponseLimit {
        case controls(maxBytes: Int)
        case catalog

        var maxBytes: Int {
            switch self {
            case .controls(let maxBytes): return maxBytes
            case .catalog: return CatalogLimits.responseBytes
            }
        }

        func exceeded(in function: String) -> ItoError {
            switch self {
            case .controls: return .controlContractViolation(function: function, violation: .init(.responseTooLarge))
            case .catalog: return .catalogContractViolation(function: function, violation: .init(.responseTooLarge))
            }
        }
    }

    /// Runs an export that returns a packed `(pointer << 32) | length` result and returns the result
    /// bytes, or nil when the export returned 0. The SDK returns 0 both for "nothing" (no settings,
    /// an unsupported image) and for failures; a failure is told apart by what the plugin reported,
    /// see `failure(of:)`.
    private func callPacked(
        _ name: String, _ arguments: [ExportArgument] = [], limit: ResponseLimit? = nil,
        remainingEditionsBytes: Int? = nil
    ) throws -> [UInt8]? {
        var allocations: [(ptr: Int32, len: Int32)] = []
        defer {
            for allocation in allocations {
                deallocBytes(ptr: allocation.ptr, len: allocation.len)
            }
        }
        var values: [Value] = []
        for argument in arguments {
            switch argument {
            case .bytes(let bytes):
                let allocation = try allocBytes(bytes)
                allocations.append(allocation)
                values.append(.i32(UInt32(bitPattern: allocation.ptr)))
                values.append(.i32(UInt32(bitPattern: allocation.len)))
            case .int(let value):
                values.append(.i32(UInt32(bitPattern: value)))
            case .flag(let value):
                values.append(.i32(value ? 1 : 0))
            }
        }

        bridge?.beginCall(name)
        let result = try executeExport(name, args: values)
        guard let resultValue = result.first, case .i64(let packed) = resultValue else {
            throw ItoError.wasmTrap("Expected i64 packed pointer response from \(name)")
        }
        guard packed != 0 else { return nil }

        let responseLength = Int(packed & 0xFFFF_FFFF)
        let responsePointer = Int(packed >> 32)
        defer {
            deallocBytes(
                ptr: Int32(bitPattern: UInt32(responsePointer)),
                len: Int32(bitPattern: UInt32(responseLength)))
        }
        if let limit, responseLength > limit.maxBytes {
            throw limit.exceeded(in: name)
        }
        if let remainingEditionsBytes, responseLength > remainingEditionsBytes {
            throw EditionsByteBound()
        }
        return try readMemory(offset: responsePointer, length: responseLength)
    }

    /// What the export that just ran reported: the typed failure from its `ito_last_error` export,
    /// when the plugin has one and reported through it, else the reason it printed (`.other`).
    /// Nil when it reported nothing. A report that can't be decoded falls back to the printed
    /// reason; a trap while reading it is thrown, since the plugin may now be broken.
    private func reportedFailure() throws -> (reason: String, category: PluginErrorCategory)? {
        let printed = bridge?.takeReportedFailure()
        if isExported("ito_last_error"),
           let bytes = try callPacked("ito_last_error"),
           let payload = try? postcardDecoder.decode(PluginErrorPayload.self, from: bytes) {
            return (payload.message, payload.category)
        }
        return printed.map { ($0, .other) }
    }

    private func isUnsupported(_ failure: (reason: String, category: PluginErrorCategory)) -> Bool {
        failure.category == .unsupported
    }

    /// The error for a failure `function` reported. A contract violation keeps only the rule it
    /// names, when this runner lists it: the rest of its message is plugin text.
    private func itoError(of function: String, reported: (reason: String, category: PluginErrorCategory)) -> ItoError {
        if reported.category == .contractViolation {
            return .catalogContractViolation(function: function, violation: .init(reportedCode: reported.reason))
        }
        return .pluginFailed(function: function, reason: reported.reason, category: reported.category)
    }

    /// The failure of `name`, with what the plugin reported while it ran.
    private func failure(of name: String) throws -> ItoError {
        guard let reported = try reportedFailure() else {
            return .pluginFailed(function: name, reason: nil, category: .other)
        }
        return itoError(of: name, reported: reported)
    }

    /// Runs `body`, which reads or checks a chapter catalog, and reports a violation it throws as
    /// the failure of `function`.
    private static func reportingViolations<T>(of function: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let violation as CatalogContractViolation {
            throw ItoError.catalogContractViolation(function: function, violation: violation)
        }
    }

    /// Decodes a response that can carry chapters: a kind this runner doesn't know is a violation
    /// of the catalog contract, not a decoding error.
    private static func decodeCatalog<T: Decodable>(_ type: T.Type, from bytes: [UInt8], function: String) throws -> T {
        try reportingViolations(of: function) {
            try ItoPostcardDecoder(abiVersion: sharedLayoutABIVersion).decode(type, from: bytes)
        }
    }

    /// Runs an export that always returns a value on success. A 0 return is a plugin failure.
    private func callDecoding<T: Decodable>(
        _ type: T.Type,
        _ name: String,
        _ arguments: [ExportArgument] = [],
        limit: ResponseLimit? = nil
    ) throws -> T {
        guard let bytes = try callPacked(name, arguments, limit: limit) else {
            throw try failure(of: name)
        }
        return try Self.decodeCatalog(type, from: bytes, function: name)
    }

    /// Optional results: a typed refusal never becomes a capability signal merely because its
    /// text says "Unsupported operation"; only the `unsupported` category does.
    private func callOptional(_ name: String, _ arguments: [ExportArgument] = [], limit: ResponseLimit? = nil) throws -> [UInt8]? {
        if let bytes = try callPacked(name, arguments, limit: limit) { return bytes }
        guard let reported = try reportedFailure() else { return nil }
        if isUnsupported(reported) { return nil }
        throw itoError(of: name, reported: reported)
    }

    private func callBounded(_ name: String, _ args: [ExportArgument], parameters: [ValueType], maxBytes: Int) throws -> [UInt8]? {
        guard let export = instance?.exports[name] else { return nil }
        guard case .function(let function) = export,
              function.type.parameters == parameters, function.type.results == [.i64] else {
            throw ItoError.controlContractViolation(function: name, violation: .init(.signature))
        }
        if let bytes = try callPacked(name, args, limit: .controls(maxBytes: maxBytes)) { return bytes }
        guard let reported = try reportedFailure() else { return nil }
        if isUnsupported(reported) { return nil }
        throw itoError(of: name, reported: reported)
    }

    private func decodeControls<T>(_ name: String, _ decode: () throws -> T) throws -> T {
        do { return try decode() }
        catch let violation as ControlContractViolation {
            throw ItoError.controlContractViolation(function: name, violation: violation)
        }
        catch let error as ItoError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ItoError.postcardDecodingError("Malformed rich controls payload.") }
    }

    private func capabilities(_ kind: Int32) throws -> CapabilitiesEntry {
        if let entry = capabilitiesByKind[kind] { return entry }
        let entry: CapabilitiesEntry
        do {
            if let bytes = try callBounded("get_search_capabilities", [.int(kind)], parameters: [.i32], maxBytes: ControlLimits.capabilitiesBytes) {
                entry = .available(try decodeControls("get_search_capabilities") { try ControlsDecoder.searchCapabilities(bytes) })
            } else { entry = .absent }
        } catch let error as ItoError where !error.isCrash {
            // Cancellation and policy are decided after the entry is built, below, never cached.
            entry = .failed(error)
        }
        if let outcome = bridge?.activeCallToken?.policyOutcome { throw ItoError.networkPolicy(outcome) }
        if bridge?.activeCallToken?.isCancelled == true { throw CancellationError() }
        capabilitiesByKind[kind] = entry
        return entry
    }

    public func getSettingsSurface(context: NetworkOperationContext) async throws -> SettingsSurface? {
        try await performSerialized(context: context) {
            var formFailure: ItoError?
            do {
                if let bytes = try self.callBounded("get_settings_form", [], parameters: [], maxBytes: ControlLimits.formBytes) {
                    return .form(try self.decodeControls("get_settings_form") { try ControlsDecoder.settingsForm(bytes) })
                }
            } catch let error as ItoError where !error.isCrash { formFailure = error }
            if self.isExported("get_settings"), let bytes = try self.callOptional("get_settings") {
                return .legacy(try self.postcardDecoder.decode(SettingsSchema.self, from: bytes), formFailure: formFailure)
            }
            if let formFailure { throw formFailure }
            return nil
        }
    }

    public func getSearchCapabilities(kind: MediaKind?, context: NetworkOperationContext) async throws -> SearchCapabilities? {
        guard kind.map({ supportedKinds.contains($0) }) ?? true else { return nil }
        return try await performSerialized(context: context) {
            switch try self.capabilities(kind?.wireValue ?? -1) {
            case .available(let capabilities): return capabilities
            case .absent: return nil
            case .failed(let error): throw error
            }
        }
    }

    public func getOptionPage(_ request: OptionRequest, context: NetworkOperationContext) async throws -> OptionPage? {
        try decodeControls("get_option_page") { try ControlValidation.request(request) }
        return try await performSerialized(context: context) {
            guard let bytes = try self.callBounded("get_option_page", [.bytes(try ItoPostcardEncoder(abiVersion: sharedLayoutABIVersion).encode(request))],
                parameters: [.i32, .i32], maxBytes: ControlLimits.optionPageBytes) else { return nil }
            return try self.decodeControls("get_option_page") { try ControlsDecoder.optionPage(bytes, request: request) }
        }
    }

    public func getSearchSuggestions(query: String, kind: MediaKind?, context: NetworkOperationContext) async throws -> [SearchSuggestion]? {
        guard (1...256).contains(query.utf8.count), kind.map({ supportedKinds.contains($0) }) ?? true else { return nil }
        return try await performSerialized(context: context) {
            guard case .available(let capabilities) = try self.capabilities(kind?.wireValue ?? -1),
                  capabilities.flags.contains(.suggestions) else { return nil }
            guard let bytes = try self.callBounded("get_search_suggestions", [.bytes(Array(query.utf8)), .int(kind?.wireValue ?? -1)],
                parameters: [.i32, .i32, .i32], maxBytes: ControlLimits.suggestionsBytes) else { return nil }
            return try self.decodeControls("get_search_suggestions") { try ControlsDecoder.suggestions(bytes) }
        }
    }

    /// Runs the `mark_completed(kind, media, unit)` export.
    private func callCompletion(kind: MediaKind, mediaKey: String, unitKey: String) throws -> Bool {
        let name = "mark_completed"
        guard let exported = instance?.exports[name] else { return false }
        let parameterCount = 5
        guard case .function(let function) = exported,
              function.type.parameters.count == parameterCount,
              function.type.parameters.allSatisfy({ $0 == .i32 }),
              function.type.results.count == 1, function.type.results.first == .i32 else {
            throw ItoError.wasmTrap("Invalid completion export signature: \(name)")
        }
        let media = try allocBytes(mediaKey.utf8)
        defer { deallocBytes(ptr: media.ptr, len: media.len) }
        let unit = try allocBytes(unitKey.utf8)
        defer { deallocBytes(ptr: unit.ptr, len: unit.len) }
        var arguments: [Value] = [.i32(UInt32(bitPattern: kind.wireValue))]
        arguments += [
            .i32(UInt32(bitPattern: media.ptr)), .i32(UInt32(bitPattern: media.len)),
            .i32(UInt32(bitPattern: unit.ptr)), .i32(UInt32(bitPattern: unit.len))
        ]
        bridge?.beginCall(name)
        let result = try executeExport(name, args: arguments)
        guard case .i32(let acknowledgement)? = result.first else {
            throw ItoError.wasmTrap("Expected completion acknowledgement: \(name)")
        }
        switch acknowledgement {
        case 1: return true
        case 0:
            guard let reported = try reportedFailure() else { return false }
            if isUnsupported(reported) { return false }
            throw itoError(of: name, reported: reported)
        default:
            throw ItoError.wasmTrap("Invalid completion acknowledgement: \(name)")
        }
    }

    // MARK: - Core Execution API

    /// Executes `get_home()`
    public func getHome(context: NetworkOperationContext) async throws -> HomeLayout {
        let kinds = supportedKinds
        return try await performSerialized(context: context) {
            let home = try self.callDecoding(HomeLayout.self, "get_home")
            try Self.requireServed(home.components.flatMap(\.value.entries), by: kinds, in: "get_home")
            try Self.reportingViolations(of: "get_home") { try CatalogValidation.home(home) }
            return home
        }
    }

    /// Executes `get_settings()` if exported by the plugin. Nil when the plugin has no settings.
    public func getSettings(context: NetworkOperationContext) async throws -> SettingsSchema? {
        return try await performSerialized(context: context) {
            guard self.isExported("get_settings"),
                let bytes = try self.callOptional("get_settings")
            else { return nil }
            return try self.postcardDecoder.decode(SettingsSchema.self, from: bytes)
        }
    }

    /// Optional settings diagnostics. An empty array means none are declared; nil means unsupported.
    public func getSettingsActions(context: NetworkOperationContext) async throws -> [SettingsAction]? {
        try await performSerialized(context: context) {
            guard self.isExported("get_settings_actions"),
                let bytes = try self.callOptional("get_settings_actions")
            else { return nil }
            return try self.postcardDecoder.decode([SettingsAction].self, from: bytes)
        }
    }

    /// Runs an explicitly requested diagnostic. Hosts must provide temporary settings and must not
    /// persist writes made during the action. An empty success message is distinct from unsupported.
    public func runSettingsAction(_ actionID: String, context: NetworkOperationContext) async throws -> String? {
        try await performSerialized(context: context) {
            guard self.isExported("run_settings_action"),
                let bytes = try self.callOptional("run_settings_action", [.bytes(Array(actionID.utf8))])
            else { return nil }
            return try self.postcardDecoder.decode(String.self, from: bytes)
        }
    }

    /// Advisory local-only validation. Empty means valid; nil means validation isn't implemented.
    public func validateSettings(context: NetworkOperationContext) async throws -> [SettingIssue]? {
        try await performSerialized(context: context) {
            guard self.isExported("validate_settings"),
                let bytes = try self.callOptional("validate_settings")
            else { return nil }
            return try self.postcardDecoder.decode([SettingIssue].self, from: bytes)
        }
    }

    /// Executes `handle_url()` if exported by the plugin. Nil when the plugin doesn't handle the URL.
    public func handleUrl(_ url: String, context: NetworkOperationContext) async throws -> LinkValue? {
        try await performSerialized(context: context) {
            guard self.isExported("handle_url"),
                let bytes = try self.callOptional("handle_url", [.bytes(Array(url.utf8))], limit: .catalog)
            else { return nil }
            // A link can carry a manga or novel with its chapters.
            let link = try Self.decodeCatalog(LinkValue.self, from: bytes, function: "handle_url")
            try Self.reportingViolations(of: "handle_url") { try CatalogValidation.link(link) }
            return link
        }
    }

    /// Executes `handle_image()` if exported by the plugin. Nil when the plugin doesn't handle images;
    /// throws `pluginFailed` when it tried and failed (e.g. refused the URL).
    public func handleImage(_ url: String, context: NetworkOperationContext) async throws -> Data? {
        return try await performSerialized(context: context) {
            guard self.isExported("handle_image"),
                let bytes = try self.callOptional("handle_image", [.bytes(Array(url.utf8))])
            else { return nil }
            return Data(bytes)
        }
    }

    /// Configured origins authorized for host image fetching, independently of image input.
    /// Nil when an older plugin doesn't export this or reports Unsupported.
    public func getImageOrigins(context: NetworkOperationContext) async throws -> [String]? {
        try await performSerialized(context: context) {
            guard self.isExported("get_image_origins"),
                  let bytes = try self.callOptional("get_image_origins") else { return nil }
            return try self.postcardDecoder.decode([String].self, from: bytes)
        }
    }

    /// Resolves an image locator without fetching bytes. Nil means this optional export is
    /// absent or unsupported; a reported failure is a refusal and must not trigger another
    /// fetch path. Hosts validate the returned URL against getImageOrigins before fetching.
    public func getImageRequest(_ locator: String, context: NetworkOperationContext) async throws -> PluginImageRequest? {
        try await performSerialized(context: context) {
            guard self.isExported("get_image_request"),
                  let bytes = try self.callOptional("get_image_request", [.bytes(Array(locator.utf8))])
            else { return nil }
            return try self.postcardDecoder.decode(PluginImageRequest.self, from: bytes)
        }
    }

    private func allocBytes<Bytes: Collection>(_ bytes: Bytes) throws -> (ptr: Int32, len: Int32)
    where Bytes.Element == UInt8 {
        let length = bytes.count
        if length == 0 { return (0, 0) }
        guard let signedLength = Int32(exactly: length) else {
            throw ItoError.wasmTrap("Argument length exceeds i32")
        }
        let allocResult = try self.executeExport("alloc", args: [.i32(UInt32(signedLength))])
        guard let pointerVal = allocResult.first, case .i32(let pointer) = pointerVal else {
            throw ItoError.wasmTrap("Failed to allocate memory")
        }
        do {
            try writeMemoryBytes(offset: Int(pointer), bytes: bytes)
        } catch {
            deallocBytes(ptr: Int32(bitPattern: pointer), len: signedLength)
            throw error
        }
        return (Int32(bitPattern: pointer), signedLength)
    }

    private func deallocBytes(ptr: Int32, len: Int32) {
        if len == 0 || ptr == 0 { return }
        do {
            _ = try self.executeExport(
                "dealloc", args: [.i32(UInt32(bitPattern: ptr)), .i32(UInt32(bitPattern: len))])
        } catch {
            RunnerLogger.core.error("[ItoRunner] Warning: Failed to dealloc memory at \(ptr) (len \(len))")
        }
    }

    // MARK: - Catalog

    /// Plugins read their arguments in the one layout of the supported ABI.
    private static let encoder = ItoPostcardEncoder(abiVersion: sharedLayoutABIVersion)

    /// A plugin declared the kinds it serves; an entry of another kind is a plugin error, not
    /// something to show.
    private static func requireServed(_ entries: [MediaEntry], by kinds: [MediaKind], in function: String) throws {
        guard let stray = entries.first(where: { !kinds.contains($0.kind) }) else { return }
        throw ItoError.pluginFailed(
            function: function, reason: "The plugin returned a kind it doesn't serve (\(stray.kind.rawValue)).")
    }

    /// Lists a page of `listing`.
    public func getListing(_ listing: Listing, page: Int32, context: NetworkOperationContext) async throws -> MediaPageResult {
        let kinds = supportedKinds
        return try await performSerialized(context: context) {
            let arguments: [ExportArgument] = [.bytes(try Self.encoder.encode(listing)), .int(page)]
            let result = try self.callDecoding(MediaPageResult.self, "get_listing", arguments)
            try Self.requireServed(result.entries, by: kinds, in: "get_listing")
            try Self.reportingViolations(of: "get_listing") { try CatalogValidation.entries(result.entries) }
            return result
        }
    }

    /// Searches for `query`, among entries of `kind`, or of every kind the plugin serves when nil.
    /// A kind the plugin doesn't serve finds nothing without calling it.
    public func search(query: String, page: Int32, kind: MediaKind? = nil, filterValues: [String: ControlValue] = [:], context: NetworkOperationContext)
        async throws -> MediaPageResult {
        let kinds = supportedKinds
        if let kind, !kinds.contains(kind) {
            return MediaPageResult(entries: [], hasNextPage: false)
        }
        return try await performSerialized(context: context) {
            let filters: [FilterItem]
            if case .available(let capabilities) = try self.capabilities(kind?.wireValue ?? -1) {
                filters = capabilities.filterItems(values: filterValues)
            } else { filters = [] }
            let arguments: [ExportArgument] = [
                .bytes(Array(query.utf8)), .int(page), .int(kind?.wireValue ?? -1),
                .bytes(try Self.encoder.encode(filters))
            ]
            let result = try self.callDecoding(MediaPageResult.self, "search", arguments)
            try Self.requireServed(result.entries, by: kinds, in: "search")
            try Self.reportingViolations(of: "search") { try CatalogValidation.entries(result.entries) }
            return result
        }
    }

    /// Fills in `entry`'s details and/or its chapters or episodes. The result is the same kind.
    /// The entry reaches the plugin without its catalog, which describes the list the plugin is
    /// about to replace, and the response may not exceed `CatalogLimits.responseBytes`.
    public func getMediaUpdate(_ entry: MediaEntry, needsDetails: Bool = true, needsUnits: Bool = true, context: NetworkOperationContext)
        async throws -> MediaEntry {
        try await performSerialized(context: context) {
            let arguments: [ExportArgument] = [
                .bytes(try Self.encoder.encode(entry.resolvingChapterKinds().withoutCatalog())),
                .flag(needsDetails), .flag(needsUnits)
            ]
            let updated = try self.callDecoding(MediaEntry.self, "get_media_update", arguments, limit: .catalog)
            guard updated.kind == entry.kind else {
                throw ItoError.pluginFailed(
                    function: "get_media_update", reason: "The plugin returned a different kind of entry.")
            }
            try Self.reportingViolations(of: "get_media_update") { try CatalogValidation.entry(updated) }
            return updated
        }
    }

    /// The pages of `chapter`, one of `entry`'s, to read as `entry.contentKind(of:)` says.
    public func getChapterPages(entry: MediaEntry, chapter: Chapter, context: NetworkOperationContext) async throws -> [Page] {
        try await performSerialized(context: context) {
            var chapter = chapter
            chapter.kind = entry.contentKind(of: chapter)
            return try self.callDecoding(
                [Page].self, "get_chapter_pages",
                [.bytes(try Self.encoder.encode(entry.resolvingChapterKinds())), .bytes(try Self.encoder.encode(chapter))])
        }
    }

    // MARK: - Chapter editions

    private static let editionsExport = "get_chapter_editions"

    /// The response fits the page limit, but not the traversal's remaining encoded-byte budget.
    private struct EditionsByteBound: Error {}

    /// One page as the plugin returned it, and how many bytes it took.
    private struct EditionsPageResponse: Sendable {
        let page: ChapterEditionsPage
        let encodedBytes: Int
    }

    /// Runs a check of editions that reports its violations as the failure of `function`.
    private static func reportingEditionsViolations<T>(of function: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let violation as ChapterEditionsViolation {
            throw ItoError.chapterEditionsViolation(function: function, violation: violation)
        }
        catch let violation as CatalogContractViolation {
            throw ItoError.catalogContractViolation(function: function, violation: violation)
        }
    }

    /// The error for a failure `get_chapter_editions` reported. A contract violation keeps only the
    /// rule it names, when this runner lists it.
    private func editionsError(of function: String, reported: (reason: String, category: PluginErrorCategory)) -> ItoError {
        if reported.category == .contractViolation,
           let violation = ChapterEditionsViolation(reportedCode: reported.reason) {
            return .chapterEditionsViolation(function: function, violation: violation)
        }
        return itoError(of: function, reported: reported)
    }

    /// Runs one `get_chapter_editions` call. Nil means the export is absent or reported Unsupported.
    /// A return of 0 without a report is a failure, not a refusal to take part.
    private func callChapterEditionsPage(_ request: ChapterEditionsRequest, remainingBytes: Int) throws -> EditionsPageResponse? {
        let name = Self.editionsExport
        guard let exported = instance?.exports[name] else { return nil }
        guard case .function(let function) = exported,
              function.type.parameters == [.i32, .i32], function.type.results == [.i64] else {
            throw ItoError.wasmTrap("Invalid chapter editions export signature: \(name)")
        }
        guard let bytes = try callPacked(
            name, [.bytes(try Self.encoder.encode(request))], limit: .catalog,
            remainingEditionsBytes: remainingBytes
        ) else {
            guard let reported = try reportedFailure() else {
                throw ItoError.pluginFailed(function: name, reason: nil, category: .other)
            }
            if isUnsupported(reported) { return nil }
            throw editionsError(of: name, reported: reported)
        }
        let page = try Self.decodeCatalog(ChapterEditionsPage.self, from: bytes, function: name)
        return EditionsPageResponse(page: page, encodedBytes: bytes.count)
    }

    /// Lists the alternative uploads of `entry`'s chapters, a manga's or a novel's, by calling the
    /// plugin's optional `get_chapter_editions` export page after page until it has no more. Call it
    /// only for an explicit user action.
    ///
    /// `limit` is the most chapters a page may carry, 1 to `ChapterEditionsLimits.maxLimit`. The
    /// entry reaches the plugin without its chapters and catalog. Pages are fetched one at a time
    /// under `context`, whose operation stays the same and whose generation is fresh for every page,
    /// and the runner owns every check across them (see `ChapterEditionsResult`): exact keys, group
    /// names, cursors, the constant scope and the caps of `ChapterEditionsLimits`.
    ///
    /// - Returns: Nil when the plugin doesn't take part: the export is absent, or the first page
    ///   reported Unsupported, or the plugin doesn't serve the entry's kind. Otherwise the whole
    ///   traversal, only after every page passed. A traversal that reached a cap says so in
    ///   `termination` and is never `complete`.
    /// - Throws: Anything else, with nothing of the traversal kept: a request or page that breaks
    ///   the contract (`chapterEditionsViolation`, `catalogContractViolation`), a malformed or
    ///   oversized response, a failure the plugin reported, Unsupported on a later page (a
    ///   `pluginFailed` of that category), `networkPolicy`, `CancellationError`, and `pluginReloaded`
    ///   when the plugin is loaded again before the traversal ends. Cursors live only in this call.
    public func getChapterEditions(
        _ entry: MediaEntry, limit: Int = ChapterEditionsLimits.maxLimit, context: NetworkOperationContext
    ) async throws -> ChapterEditionsResult? {
        try await traverseChapterEditions(entry, limit: limit, context: context, afterPage: nil)
    }

    /// `getChapterEditions`, calling `afterPage` with the number of pages taken so far each time
    /// another page is due, so a test can act between pages.
    func traverseChapterEditions(
        _ entry: MediaEntry, limit: Int, context: NetworkOperationContext,
        afterPage: (@Sendable (Int) async -> Void)?
    ) async throws -> ChapterEditionsResult? {
        let name = Self.editionsExport
        let pageLimit = UInt32(clamping: limit)
        let stripped = entry.withoutChapters()
        try Self.reportingEditionsViolations(of: name) {
            try ChapterEditionsValidation.request(ChapterEditionsRequest(entry: stripped, cursor: nil, limit: pageLimit))
        }
        guard supportedKinds.contains(entry.kind) else { return nil }

        // The whole traversal belongs to the plugin loaded now.
        let bound = invocationState.generation
        var sequence = ChapterEditionsSequence(limit: pageLimit)
        var cursor: String?
        while true {
            try Task.checkCancellation()
            guard invocationState.generation == bound else { throw ItoError.pluginReloaded }
            let request = ChapterEditionsRequest(entry: stripped, cursor: cursor, limit: pageLimit)
            let remainingBytes = ChapterEditionsLimits.maxCumulativeBytes - sequence.encodedBytes
            let response: EditionsPageResponse?
            do {
                response = try await performSerialized(context: context.withGeneration(UUID()), boundTo: bound) {
                    try self.callChapterEditionsPage(request, remainingBytes: remainingBytes)
                }
            } catch is EditionsByteBound {
                try Task.checkCancellation()
                guard invocationState.generation == bound else { throw ItoError.pluginReloaded }
                _ = sequence.stop(at: .bytes)
                return sequence.result()
            }
            try Task.checkCancellation()
            guard invocationState.generation == bound else { throw ItoError.pluginReloaded }
            guard let response else {
                if sequence.pageCount == 0 { return nil }
                throw ItoError.pluginFailed(function: name, reason: nil, category: .unsupported)
            }
            let step = try Self.reportingEditionsViolations(of: name) {
                try sequence.accept(response.page, encodedBytes: response.encodedBytes)
            }
            switch step {
            case .finished:
                return sequence.result()
            case .next(let next):
                cursor = next
                await afterPage?(sequence.pageCount)
            }
        }
    }

    /// The streams of `episode`, one of `anime`'s.
    public func getEpisodeVideos(anime: Anime, episode: Anime.Episode, context: NetworkOperationContext) async throws -> [Anime.Video] {
        try await performSerialized(context: context) {
            try self.callDecoding(
                [Anime.Video].self, "get_episode_videos",
                [.bytes(try Self.encoder.encode(anime)), .bytes(try Self.encoder.encode(episode))])
        }
    }

    /// Reports completion of a chapter or episode after local progress has committed. True
    /// acknowledges delivery; false means absent/unsupported. Reported failures throw. Calls may
    /// be retried idempotently.
    public func markCompleted(kind: MediaKind, mediaKey: String, unitKey: String, context: NetworkOperationContext) async throws -> Bool {
        try await performSerialized(context: context) {
            try self.callCompletion(kind: kind, mediaKey: mediaKey, unitKey: unitKey)
        }
    }
}

extension HomeComponentValue {
    /// The entries the component shows.
    var entries: [MediaEntry] {
        switch self {
        case .scroller(let manga, _), .mangaList(_, _, let manga, _), .bigScroller(let manga, _):
            return manga.map(MediaEntry.manga)
        case .mangaChapterList(_, let items, _):
            return items.map { .manga($0.manga) }
        case .animeScroller(let anime, _), .animeList(_, _, let anime, _), .animeBigScroller(let anime, _):
            return anime.map(MediaEntry.anime)
        case .animeEpisodeList(_, let items, _):
            return items.map { .anime($0.anime) }
        case .novelScroller(let novels, _), .novelList(_, _, let novels, _), .novelBigScroller(let novels, _):
            return novels.map(MediaEntry.novel)
        case .novelChapterList(_, let items, _):
            return items.map { .novel($0.novel) }
        case .mediaScroller(let entries, _), .mediaList(_, _, let entries, _), .mediaBigScroller(let entries, _):
            return entries
        case .filters, .links:
            return []
        }
    }
}

extension MediaEntry {
    /// This entry with every chapter's kind known, as plugins receive it.
    func resolvingChapterKinds() -> MediaEntry {
        func resolved(_ chapters: [Chapter]?, _ kind: MediaKind) -> [Chapter]? {
            chapters?.map { chapter in
                var chapter = chapter
                chapter.kind = chapter.kind ?? kind.defaultContentKind
                return chapter
            }
        }
        switch self {
        case .manga(var manga):
            manga.chapters = resolved(manga.chapters, .manga)
            return .manga(manga)
        case .novel(var novel):
            novel.chapters = resolved(novel.chapters, .novel)
            return .novel(novel)
        case .anime:
            return self
        }
    }

    /// This entry without the catalog describing its chapter list. A plugin that is asked for a
    /// fresh list never receives the saved one.
    func withoutCatalog() -> MediaEntry {
        switch self {
        case .manga(var manga):
            manga.catalog = nil
            return .manga(manga)
        case .novel(var novel):
            novel.catalog = nil
            return .novel(novel)
        case .anime:
            return self
        }
    }
}

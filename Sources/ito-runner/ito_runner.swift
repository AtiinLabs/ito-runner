import OSLog
import Foundation
import WasmKit
import ZIPFoundation

/// The main execution engine for ito-runner.
/// It wraps WasmKit to load, instantiate, and execute WebAssembly plugins.
public actor ItoRunner {

    /// The running WasmKit Instance. We hold onto it so we can execute exports later.
    private var instance: Instance?

    /// The memory space shared by the Wasm plugin and swift.
    private var memory: Memory?
    private var errorProtocolVersion: UInt32 = 1

    /// The ABI the loaded plugin was built for (`ito_abi_version`).
    public private(set) var abiVersion = 1
    /// The kinds the loaded plugin serves. Plugins built for ABI 1 serve one, named by their exports.
    public private(set) var supportedKinds: [MediaKind] = []

    /// Decodes payloads laid out the same in every ABI (settings, errors, image requests).
    private let postcardDecoder = ItoPostcardDecoder()

    private enum CapabilitiesEntry {
        case available(SearchCapabilities), absent, failed(ItoError)
    }
    private var capabilitiesByKind: [Int32: CapabilitiesEntry] = [:]

    /// The FFI Bridge that connects Host Modules to Wasm. Created upon plugin load.
    public var bridge: WasmBridge?

    public var netModule: NetModule?
    public var htmlModule: HtmlModule?
    public var stdModule: StdModule?
    public var defaultsModule: DefaultsModule?
    public var envModule: EnvModule?
    public var webviewModule: WebviewModule?

    private let executionQueue = DispatchQueue(label: "moe.itoapp.runner.execution")

    /// How long host work (network, web view) may block a plugin call. Applies to plugins loaded
    /// after it is set.
    public private(set) var hostCallTimeouts = HostCallTimeouts()

    /// Runs one job on the runner's queue, one at a time. Cancelling the caller's task skips the job
    /// if it hasn't started, and cancels host work it is waiting on if it has; either way the caller
    /// gets `CancellationError`, never the failure the cancellation caused in the plugin.
    private func performSerialized<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let token = CallToken()
        // Read on the actor: the queue never touches runner state after resuming the caller.
        let bridge = self.bridge
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executionQueue.async {
                    guard !token.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    bridge?.activeCallToken = token
                    do {
                        let result = try operation()
                        bridge?.activeCallToken = nil
                        if token.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: result)
                        }
                    } catch {
                        bridge?.activeCallToken = nil
                        continuation.resume(throwing: token.isCancelled ? CancellationError() : error)
                    }
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

    /// The ABI versions (`ito_abi_version`) of plugins this runner can run. A plugin without the
    /// export was built before it existed, which is version 1.
    public static let supportedABIVersions: ClosedRange<Int> = 1...2

    /// The host functions this runner provides, by module ("ito:core/net") and name.
    public static let supportedImports: [String: Set<String>] = WasmBridge(runner: ItoRunner())
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
    /// this runner lacks, or was built for an unsupported ABI, is refused before it can run.
    public func loadPlugin(fromBytes wasmBytes: [UInt8]) throws {
        do {
            // 1. Initialize a new Wasm Engine & Store
            let engine = Engine()
            let store = Store(engine: engine)

            // 2. Parse the Wasm Module
            let module = try parseWasm(bytes: wasmBytes)

            // 3. Setup Imports
            let bridge = WasmBridge(runner: self)
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

            // 4. Instantiate the plugin, and keep it only if its ABI is supported and it exports
            // its memory. Nothing of a previously loaded plugin is touched until then.
            let instance = try module.instantiate(store: store, imports: imports)
            let abi = try Self.abiVersion(of: instance)
            guard Self.supportedABIVersions.contains(abi) else {
                throw ItoError.unsupportedABI(version: abi, supported: Self.supportedABIVersions)
            }
            guard case .memory(let memory)? = instance.exports["memory"] else {
                throw ItoError.wasmTrap("Plugin did not export linear 'memory'.")
            }
            let errorProtocolVersion = try Self.errorReportVersion(of: instance)
            let kinds = try Self.supportedKinds(of: instance, abi: abi)

            // Clear any lingering state from previous runs
            bridge.htmlModule?.clear()
            self.instance = instance
            self.bridge = bridge
            self.memory = memory
            self.errorProtocolVersion = errorProtocolVersion
            self.abiVersion = abi
            self.supportedKinds = kinds
            self.capabilitiesByKind.removeAll()

        } catch let error as ItoError {
            throw error
        } catch {
            throw ItoError.wasmTrap("Failed to load Wasm plugin: \(error.localizedDescription)")
        }
    }

    /// The ABI version `instance` was built for: its `ito_abi_version` export, or 1 without one.
    private static func abiVersion(of instance: Instance) throws -> Int {
        guard case .function(let function)? = instance.exports["ito_abi_version"] else { return 1 }
        guard case .i32(let version)? = try function([]).first else {
            throw ItoError.wasmTrap("ito_abi_version must return an i32")
        }
        return Int(version)
    }

    /// The list export each kind's ABI 1 plugin has.
    private static let legacyListExports: [MediaKind: String] = [
        .manga: "get_manga_list", .anime: "get_anime_list", .novel: "get_novel_list"
    ]

    /// The kinds `instance` serves: its `ito_supported_kinds` mask from ABI 2, or for an older
    /// plugin the kind whose exports it has.
    private static func supportedKinds(of instance: Instance, abi: Int) throws -> [MediaKind] {
        guard abi >= 2 else {
            return MediaKind.allCases.filter { kind in
                legacyListExports[kind].map { instance.exports[$0] != nil } ?? false
            }
        }
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

    /// Version 1 encoded Unsupported as an ordinary failure message. Version 2 gives it an
    /// explicit category. A malformed version export must not silently downgrade the protocol.
    private static func errorReportVersion(of instance: Instance) throws -> UInt32 {
        guard let exported = instance.exports["ito_error_version"] else { return 1 }
        guard case .function(let function) = exported,
              function.type.parameters.isEmpty,
              function.type.results.count == 1,
              function.type.results.first == .i32 else {
            throw ItoError.wasmTrap("ito_error_version must be () -> i32")
        }
        guard case .i32(let version)? = try function([]).first, version > 0 else {
            throw ItoError.wasmTrap("ito_error_version must return a positive version")
        }
        return version
    }

    /// Loads a packaged `.ito` bundle, extracting the wasm logic and returning the manifest.
    public func loadBundle(from url: URL) throws -> PluginManifest? {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ItoError.wasmTrap("Failed to read .ito archive at \(url)")
        }

        var manifest: PluginManifest?
        var wasmBytes: [UInt8]?

        for entry in archive {
            if entry.path.hasSuffix(".json") {
                var data = Data()
                _ = try archive.extract(entry) { dict in
                    data.append(dict)
                }
                manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            } else if entry.path.hasSuffix(".wasm") {
                var data = Data()
                _ = try archive.extract(entry) { dict in
                    data.append(dict)
                }
                wasmBytes = [UInt8](data)
            }
        }

        guard let wasm = wasmBytes else {
            throw ItoError.wasmTrap("Archive did not contain a .wasm file.")
        }

        try loadPlugin(fromBytes: wasm)
        return manifest
    }

    /// Statically extracts the manifest and optional icon from an `.ito` bundle without loading the Wasm module.
    public static func extractPluginInfo(from url: URL) throws -> (manifest: PluginManifest, icon: Data?) {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ItoError.wasmTrap("Failed to read .ito archive at \(url)")
        }

        var manifest: PluginManifest?
        var iconData: Data?

        for entry in archive {
            if entry.path.hasSuffix(".json") {
                var data = Data()
                _ = try archive.extract(entry) { dict in
                    data.append(dict)
                }
                manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            } else if entry.path.lowercased().hasSuffix("icon.png") || entry.path.lowercased().hasSuffix("icon.jpg") {
                var data = Data()
                _ = try archive.extract(entry) { dict in
                    data.append(dict)
                }
                iconData = data
            }
        }

        guard let finalManifest = manifest else {
            throw ItoError.wasmTrap("Archive did not contain a manifest file.")
        }

        return (finalManifest, iconData)
    }

    // MARK: - Memory Utilities

    /// Reads a slice of bytes from the Wasm linear memory.
    /// - Parameters:
    ///   - offset: The starting byte offset in Wasm memory.
    ///   - length: The number of bytes to read.
    /// - Returns: An array of bytes.
    /// - Throws: `ItoError.memoryOutOfBounds` if the requested range is outside memory bounds.
    public func readMemory(offset: Int, length: Int) throws -> [UInt8] {
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
    public func writeMemory(offset: Int, bytes: [UInt8]) throws {
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
    public func executeExport(_ name: String, args: [Value] = []) throws -> [Value] {
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

    /// Runs an export that returns a packed `(pointer << 32) | length` result and returns the result
    /// bytes, or nil when the export returned 0. The SDK returns 0 both for "nothing" (no settings,
    /// an unsupported image) and for failures; a failure is told apart by the reason the plugin
    /// printed, see `failure(of:)`.
    private func callPacked(_ name: String, _ arguments: [ExportArgument] = [], maxBytes: Int? = nil) throws -> [UInt8]? {
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
        if let maxBytes, responseLength > maxBytes {
            throw ItoError.controlContractViolation(function: name, violation: .init(.responseTooLarge))
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
        failure.category == .unsupported ||
            (errorProtocolVersion == 1 && failure.category == .other &&
                failure.reason == WasmBridge.unsupportedReason)
    }

    /// The failure of `name`, with what the plugin reported while it ran.
    private func failure(of name: String) throws -> ItoError {
        let reported = try reportedFailure()
        return .pluginFailed(function: name, reason: reported?.reason, category: reported?.category ?? .other)
    }

    /// Runs an export that always returns a value on success. A 0 return is a plugin failure.
    /// `abi` is the layout to read, from the caller's `Contract`.
    private func callDecoding<T: Decodable>(
        _ type: T.Type,
        _ name: String,
        _ arguments: [ExportArgument] = [],
        abi: Int
    ) throws -> T {
        guard let bytes = try callPacked(name, arguments) else {
            throw try failure(of: name)
        }
        return try ItoPostcardDecoder(abiVersion: abi).decode(T.self, from: bytes)
    }

    /// Optional results preserve legacy protocol-1 Unsupported messages, but typed refusals
    /// never become capability signals merely because their text says "Unsupported operation".
    private func callOptional(_ name: String, _ arguments: [ExportArgument] = []) throws -> [UInt8]? {
        if let bytes = try callPacked(name, arguments) { return bytes }
        guard let reported = try reportedFailure() else { return nil }
        if isUnsupported(reported) { return nil }
        throw ItoError.pluginFailed(function: name, reason: reported.reason, category: reported.category)
    }

    private func callBounded(_ name: String, _ args: [ExportArgument], parameters: [ValueType], maxBytes: Int) throws -> [UInt8]? {
        guard abiVersion >= 2, let export = instance?.exports[name] else { return nil }
        guard case .function(let function) = export,
              function.type.parameters == parameters, function.type.results == [.i64] else {
            throw ItoError.controlContractViolation(function: name, violation: .init(.signature))
        }
        if let bytes = try callPacked(name, args, maxBytes: maxBytes) { return bytes }
        guard let reported = try reportedFailure() else { return nil }
        if isUnsupported(reported) { return nil }
        throw ItoError.pluginFailed(function: name, reason: reported.reason, category: reported.category)
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
            if bridge?.activeCallToken?.isCancelled == true { throw CancellationError() }
            entry = .failed(error)
        }
        if bridge?.activeCallToken?.isCancelled == true { throw CancellationError() }
        capabilitiesByKind[kind] = entry
        return entry
    }

    public func getSettingsSurface() async throws -> SettingsSurface? {
        try await performSerialized {
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

    public func getSearchCapabilities(kind: MediaKind?) async throws -> SearchCapabilities? {
        guard abiVersion >= 2, kind.map({ supportedKinds.contains($0) }) ?? true else { return nil }
        return try await performSerialized {
            switch try self.capabilities(kind?.wireValue ?? -1) {
            case .available(let capabilities): return capabilities
            case .absent: return nil
            case .failed(let error): throw error
            }
        }
    }

    public func getOptionPage(_ request: OptionRequest) async throws -> OptionPage? {
        try decodeControls("get_option_page") { try ControlValidation.request(request) }
        return try await performSerialized {
            guard let bytes = try self.callBounded("get_option_page", [.bytes(try ItoPostcardEncoder().encode(request))],
                parameters: [.i32, .i32], maxBytes: ControlLimits.optionPageBytes) else { return nil }
            return try self.decodeControls("get_option_page") { try ControlsDecoder.optionPage(bytes, request: request) }
        }
    }

    public func getSearchSuggestions(query: String, kind: MediaKind?) async throws -> [SearchSuggestion]? {
        guard (1...256).contains(query.utf8.count), abiVersion >= 2,
              kind.map({ supportedKinds.contains($0) }) ?? true else { return nil }
        return try await performSerialized {
            guard case .available(let capabilities) = try self.capabilities(kind?.wireValue ?? -1),
                  capabilities.flags.contains(.suggestions) else { return nil }
            guard let bytes = try self.callBounded("get_search_suggestions", [.bytes(Array(query.utf8)), .int(kind?.wireValue ?? -1)],
                parameters: [.i32, .i32, .i32], maxBytes: ControlLimits.suggestionsBytes) else { return nil }
            return try self.decodeControls("get_search_suggestions") { try ControlsDecoder.suggestions(bytes) }
        }
    }

    /// Runs a completion export: ABI 1's `mark_chapter_read`/`mark_episode_watched(media, unit)`, or
    /// ABI 2's `mark_completed(kind, media, unit)` when `kind` is given.
    private func callCompletion(_ name: String, kind: MediaKind? = nil, mediaKey: String, unitKey: String) throws -> Bool {
        guard let exported = instance?.exports[name] else { return false }
        let parameterCount = kind == nil ? 4 : 5
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
        var arguments: [Value] = kind.map { [.i32(UInt32(bitPattern: $0.wireValue))] } ?? []
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
            throw ItoError.pluginFailed(function: name, reason: reported.reason, category: reported.category)
        default:
            throw ItoError.wasmTrap("Invalid completion acknowledgement: \(name)")
        }
    }

    // MARK: - Core Execution API

    /// Executes `get_home()`
    public func getHome() async throws -> HomeLayout {
        let contract = self.contract
        return try await performSerialized {
            let home = try self.callDecoding(HomeLayout.self, "get_home", abi: contract.abi)
            try Self.requireServed(home.components.flatMap(\.value.entries), by: contract, in: "get_home")
            return home
        }
    }

    /// Executes `get_settings()` if exported by the plugin. Nil when the plugin has no settings.
    public func getSettings() async throws -> SettingsSchema? {
        return try await performSerialized {
            guard self.isExported("get_settings"),
                let bytes = try self.callOptional("get_settings")
            else { return nil }
            return try self.postcardDecoder.decode(SettingsSchema.self, from: bytes)
        }
    }

    /// Optional settings diagnostics. An empty array means none are declared; nil means unsupported.
    public func getSettingsActions() async throws -> [SettingsAction]? {
        try await performSerialized {
            guard self.isExported("get_settings_actions"),
                let bytes = try self.callOptional("get_settings_actions")
            else { return nil }
            return try self.postcardDecoder.decode([SettingsAction].self, from: bytes)
        }
    }

    /// Runs an explicitly requested diagnostic. Hosts must provide temporary settings and must not
    /// persist writes made during the action. An empty success message is distinct from unsupported.
    public func runSettingsAction(_ actionID: String) async throws -> String? {
        try await performSerialized {
            guard self.isExported("run_settings_action"),
                let bytes = try self.callOptional("run_settings_action", [.bytes(Array(actionID.utf8))])
            else { return nil }
            return try self.postcardDecoder.decode(String.self, from: bytes)
        }
    }

    /// Advisory local-only validation. Empty means valid; nil means validation isn't implemented.
    public func validateSettings() async throws -> [SettingIssue]? {
        try await performSerialized {
            guard self.isExported("validate_settings"),
                let bytes = try self.callOptional("validate_settings")
            else { return nil }
            return try self.postcardDecoder.decode([SettingIssue].self, from: bytes)
        }
    }

    /// Executes `handle_url()` if exported by the plugin. Nil when the plugin doesn't handle the URL.
    public func handleUrl(_ url: String) async throws -> LinkValue? {
        let abi = abiVersion
        return try await performSerialized {
            guard self.isExported("handle_url"),
                let bytes = try self.callOptional("handle_url", [.bytes(Array(url.utf8))])
            else { return nil }
            // A link can carry a manga or novel with its chapters, laid out as the plugin's ABI says.
            return try ItoPostcardDecoder(abiVersion: abi).decode(LinkValue.self, from: bytes)
        }
    }

    /// Executes `handle_image()` if exported by the plugin. Nil when the plugin doesn't handle images;
    /// throws `pluginFailed` when it tried and failed (e.g. refused the URL).
    public func handleImage(_ url: String) async throws -> Data? {
        return try await performSerialized {
            guard self.isExported("handle_image"),
                let bytes = try self.callOptional("handle_image", [.bytes(Array(url.utf8))])
            else { return nil }
            return Data(bytes)
        }
    }

    /// Configured origins authorized for host image fetching, independently of image input.
    /// Nil when an older plugin doesn't export this or reports Unsupported.
    public func getImageOrigins() async throws -> [String]? {
        try await performSerialized {
            guard self.isExported("get_image_origins"),
                  let bytes = try self.callOptional("get_image_origins") else { return nil }
            return try self.postcardDecoder.decode([String].self, from: bytes)
        }
    }

    /// Resolves an image locator without fetching bytes. Nil means this optional export is
    /// absent or unsupported; a reported failure is a refusal and must not trigger another
    /// fetch path. Hosts validate the returned URL against getImageOrigins before fetching.
    public func getImageRequest(_ locator: String) async throws -> PluginImageRequest? {
        try await performSerialized {
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

    /// The loaded plugin's ABI and kinds, read on the actor before a call is queued so a call
    /// sees one consistent plugin.
    private struct Contract {
        let abi: Int
        let kinds: [MediaKind]

        var encoder: ItoPostcardEncoder { ItoPostcardEncoder(abiVersion: abi) }

        /// The kind an ABI 1 plugin serves, which picks its exports.
        func legacyKind() throws -> MediaKind {
            guard let kind = kinds.first else {
                throw ItoError.wasmTrap("The plugin exports no catalog.")
            }
            return kind
        }
    }

    private var contract: Contract { Contract(abi: abiVersion, kinds: supportedKinds) }

    /// An ABI 2 plugin declared the kinds it serves; an entry of another kind is a plugin error,
    /// not something to show. ABI 1 plugins answer with their one kind by construction.
    private static func requireServed(_ entries: [MediaEntry], by contract: Contract, in function: String) throws {
        guard contract.abi >= 2,
              let stray = entries.first(where: { !contract.kinds.contains($0.kind) }) else { return }
        throw ItoError.pluginFailed(
            function: function, reason: "The plugin returned a kind it doesn't serve (\(stray.kind.rawValue)).")
    }

    /// Lists a page of `listing`.
    public func getListing(_ listing: Listing, page: Int32) async throws -> MediaPageResult {
        let contract = self.contract
        return try await performSerialized {
            let arguments: [ExportArgument] = [.bytes(try contract.encoder.encode(listing)), .int(page)]
            let result: MediaPageResult
            if contract.abi >= 2 {
                result = try self.callDecoding(MediaPageResult.self, "get_listing", arguments, abi: contract.abi)
            } else {
                switch try contract.legacyKind() {
                case .manga:
                    result = MediaPageResult(
                        try self.callDecoding(Manga.PageResult.self, "get_manga_list", arguments, abi: contract.abi))
                case .anime:
                    result = MediaPageResult(
                        try self.callDecoding(Anime.PageResult.self, "get_anime_list", arguments, abi: contract.abi))
                case .novel:
                    result = MediaPageResult(
                        try self.callDecoding(Novel.PageResult.self, "get_novel_list", arguments, abi: contract.abi))
                }
            }
            try Self.requireServed(result.entries, by: contract, in: "get_listing")
            return result
        }
    }

    /// Searches for `query`, among entries of `kind`, or of every kind the plugin serves when nil.
    /// A kind the plugin doesn't serve finds nothing without calling it.
    public func search(query: String, page: Int32, kind: MediaKind? = nil, filterValues: [String: ControlValue] = [:])
        async throws -> MediaPageResult {
        let contract = self.contract
        if let kind, !contract.kinds.contains(kind) {
            return MediaPageResult(entries: [], hasNextPage: false)
        }
        return try await performSerialized {
            let filters: [FilterItem]
            if contract.abi >= 2, case .available(let capabilities) = try self.capabilities(kind?.wireValue ?? -1) {
                filters = capabilities.filterItems(values: filterValues)
            } else { filters = [] }
            let arguments: (Int32?) throws -> [ExportArgument] = { kind in
                [.bytes(Array(query.utf8)), .int(page)] + (kind.map { [.int($0)] } ?? [])
                    + [.bytes(try contract.encoder.encode(filters))]
            }
            let result: MediaPageResult
            if contract.abi >= 2 {
                result = try self.callDecoding(
                    MediaPageResult.self, "search", arguments(kind?.wireValue ?? -1), abi: contract.abi)
            } else {
                switch try contract.legacyKind() {
                case .manga:
                    result = MediaPageResult(try self.callDecoding(
                        Manga.PageResult.self, "get_search_manga_list", arguments(nil), abi: contract.abi))
                case .anime:
                    result = MediaPageResult(try self.callDecoding(
                        Anime.PageResult.self, "get_search_anime_list", arguments(nil), abi: contract.abi))
                case .novel:
                    result = MediaPageResult(try self.callDecoding(
                        Novel.PageResult.self, "get_search_novel_list", arguments(nil), abi: contract.abi))
                }
            }
            try Self.requireServed(result.entries, by: contract, in: "search")
            return result
        }
    }

    /// Fills in `entry`'s details and/or its chapters or episodes. The result is the same kind.
    public func getMediaUpdate(_ entry: MediaEntry, needsDetails: Bool = true, needsUnits: Bool = true)
        async throws -> MediaEntry {
        let contract = self.contract
        return try await performSerialized {
            let flags: [ExportArgument] = [.flag(needsDetails), .flag(needsUnits)]
            let encoder = contract.encoder
            let updated: MediaEntry
            if contract.abi >= 2 {
                updated = try self.callDecoding(
                    MediaEntry.self, "get_media_update",
                    [.bytes(try encoder.encode(entry.resolvingChapterKinds()))] + flags, abi: contract.abi)
            } else {
                switch entry {
                case .manga(let manga):
                    updated = .manga(try self.callDecoding(
                        Manga.self, "get_manga_update", [.bytes(try encoder.encode(manga))] + flags, abi: contract.abi))
                case .anime(let anime):
                    updated = .anime(try self.callDecoding(
                        Anime.self, "get_anime_update", [.bytes(try encoder.encode(anime))] + flags, abi: contract.abi))
                case .novel(let novel):
                    updated = .novel(try self.callDecoding(
                        Novel.self, "get_novel_update", [.bytes(try encoder.encode(novel))] + flags, abi: contract.abi))
                }
            }
            guard updated.kind == entry.kind else {
                throw ItoError.pluginFailed(
                    function: "get_media_update", reason: "The plugin returned a different kind of entry.")
            }
            return updated
        }
    }

    /// The pages of `chapter`, one of `entry`'s, to read as `entry.contentKind(of:)` says.
    public func getChapterPages(entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        let contract = self.contract
        return try await performSerialized {
            let encoder = contract.encoder
            var chapter = chapter
            chapter.kind = entry.contentKind(of: chapter)
            let chapterBytes = ExportArgument.bytes(try encoder.encode(chapter))
            if contract.abi >= 2 {
                return try self.callDecoding(
                    [Page].self, "get_chapter_pages",
                    [.bytes(try encoder.encode(entry.resolvingChapterKinds())), chapterBytes], abi: contract.abi)
            }
            switch entry {
            case .manga(let manga):
                return try self.callDecoding(
                    [Page].self, "get_page_list", [.bytes(try encoder.encode(manga)), chapterBytes], abi: contract.abi)
            case .novel(let novel):
                return try self.callDecoding(
                    [Page].self, "get_chapter_content", [.bytes(try encoder.encode(novel)), chapterBytes],
                    abi: contract.abi)
            case .anime:
                throw ItoError.pluginFailed(function: "get_chapter_pages", reason: "Anime has episodes, not chapters.")
            }
        }
    }

    /// The streams of `episode`, one of `anime`'s.
    public func getEpisodeVideos(anime: Anime, episode: Anime.Episode) async throws -> [Anime.Video] {
        let contract = self.contract
        return try await performSerialized {
            try self.callDecoding(
                [Anime.Video].self, contract.abi >= 2 ? "get_episode_videos" : "get_video_list",
                [.bytes(try contract.encoder.encode(anime)), .bytes(try contract.encoder.encode(episode))],
                abi: contract.abi)
        }
    }

    /// Reports completion of a chapter or episode after local progress has committed. True
    /// acknowledges delivery; false means absent/unsupported. Reported failures throw. Calls may
    /// be retried idempotently.
    public func markCompleted(kind: MediaKind, mediaKey: String, unitKey: String) async throws -> Bool {
        let contract = self.contract
        return try await performSerialized {
            if contract.abi >= 2 {
                return try self.callCompletion("mark_completed", kind: kind, mediaKey: mediaKey, unitKey: unitKey)
            }
            let name = kind == .anime ? "mark_episode_watched" : "mark_chapter_read"
            return try self.callCompletion(name, mediaKey: mediaKey, unitKey: unitKey)
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

extension MediaPageResult {
    init(_ page: Manga.PageResult) {
        self.init(entries: page.entries.map(MediaEntry.manga), hasNextPage: page.hasNextPage)
    }

    init(_ page: Anime.PageResult) {
        self.init(entries: page.entries.map(MediaEntry.anime), hasNextPage: page.hasNextPage)
    }

    init(_ page: Novel.PageResult) {
        self.init(entries: page.entries.map(MediaEntry.novel), hasNextPage: page.hasNextPage)
    }
}

extension MediaEntry {
    /// This entry with every chapter's kind known, as ABI 2 plugins receive it.
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
}

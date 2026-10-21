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

    /// The Object Bridge Registry, used to securely store Swift objects and pass their integer IDs to Wasm.
    public let registry: DescriptorRegistry

    /// The custom Postcard Serialization encoder and decoder.
    nonisolated public let postcardEncoder = ItoPostcardEncoder()
    nonisolated public let postcardDecoder = ItoPostcardDecoder()

    /// The FFI Bridge that connects Host Modules to Wasm. Created upon plugin load.
    public var bridge: WasmBridge?

    public var netModule: NetModule?
    public var htmlModule: HtmlModule?
    public var jsModule: JsModule?
    public var stdModule: StdModule?
    public var defaultsModule: DefaultsModule?
    public var envModule: EnvModule?
    public var uiModule: UiModule?
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
    public init() {
        self.registry = DescriptorRegistry()
    }

    public func setNetModule(_ module: NetModule) { self.netModule = module }
    public func setHtmlModule(_ module: HtmlModule) { self.htmlModule = module }
    public func setJsModule(_ module: JsModule) { self.jsModule = module }
    public func setStdModule(_ module: StdModule) { self.stdModule = module }
    public func setDefaultsModule(_ module: DefaultsModule) { self.defaultsModule = module }
    public func setEnvModule(_ module: EnvModule) { self.envModule = module }
    public func setUiModule(_ module: UiModule) { self.uiModule = module }
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
    public static let supportedABIVersions: ClosedRange<Int> = 1...1

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
            bridge.jsModule = self.jsModule
            bridge.stdModule = self.stdModule
            bridge.defaultsModule = self.defaultsModule
            bridge.envModule = self.envModule
            bridge.uiModule = self.uiModule
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

            // Clear any lingering state from previous runs
            bridge.htmlModule?.clear()
            self.instance = instance
            self.bridge = bridge
            self.memory = memory

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
        guard let memory = memory else {
            throw ItoError.wasmTrap("Memory is not initialized.")
        }

        let memData = memory.data
        let length = bytes.count

        guard offset >= 0, offset + length <= memData.count else {
            throw ItoError.memoryOutOfBounds(
                offset: offset, length: length, memorySize: memData.count)
        }

        // Write the bytes using GuestMemory API
        memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: bytes.count) {
            buffer in
            bytes.withUnsafeBytes { sourceBuffer in
                buffer.copyMemory(from: UnsafeRawBufferPointer(sourceBuffer))
            }
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
    private func callPacked(_ name: String, _ arguments: [ExportArgument] = []) throws -> [UInt8]? {
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
        return try readMemory(offset: responsePointer, length: responseLength)
    }

    /// The failure of `name`, with the reason the plugin printed while it ran.
    private func failure(of name: String) -> ItoError {
        .pluginFailed(function: name, reason: bridge?.takeReportedFailure())
    }

    /// Runs an export that always returns a value on success. A 0 return is a plugin failure.
    private func callDecoding<T: Decodable>(
        _ type: T.Type,
        _ name: String,
        _ arguments: [ExportArgument] = []
    ) throws -> T {
        guard let bytes = try callPacked(name, arguments) else {
            throw failure(of: name)
        }
        return try postcardDecoder.decode(T.self, from: bytes)
    }

    /// Runs an export where a 0 return also means "nothing": nil when the plugin reported no failure
    /// or reported it doesn't support the request, which is how the SDK says "not handled".
    private func callOptional(_ name: String, _ arguments: [ExportArgument] = []) throws -> [UInt8]? {
        if let bytes = try callPacked(name, arguments) {
            return bytes
        }
        if let reason = bridge?.takeReportedFailure(), reason != WasmBridge.unsupportedReason {
            throw ItoError.pluginFailed(function: name, reason: reason)
        }
        return nil
    }

    // MARK: - Core Execution API

    /// Executes `get_home()`
    public func getHome() async throws -> HomeLayout {
        return try await performSerialized {
            try self.callDecoding(HomeLayout.self, "get_home")
        }
    }

    /// Executes `get_home_stream()` and returns true if it pushed components directly.
    public func getHomeStream() async throws -> Bool {
        return try await performSerialized {
            guard self.isExported("get_home_stream") else { return false }

            self.bridge?.beginCall("get_home_stream")
            let result = try self.executeExport("get_home_stream")
            guard let resultVal = result.first, case .i32(let ret) = resultVal else {
                throw ItoError.wasmTrap("Expected i32 response from get_home_stream")
            }
            if ret == 0, let reason = self.bridge?.takeReportedFailure() {
                throw ItoError.pluginFailed(function: "get_home_stream", reason: reason)
            }
            return ret != 0
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

    /// Executes `handle_url()` if exported by the plugin. Nil when the plugin doesn't handle the URL.
    public func handleUrl(_ url: String) async throws -> LinkValue? {
        return try await performSerialized {
            guard self.isExported("handle_url"),
                let bytes = try self.callOptional("handle_url", [.bytes(Array(url.utf8))])
            else { return nil }
            return try self.postcardDecoder.decode(LinkValue.self, from: bytes)
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

    private func allocBytes(_ bytes: [UInt8]) throws -> (ptr: Int32, len: Int32) {
        if bytes.isEmpty { return (0, 0) }
        let allocResult = try self.executeExport("alloc", args: [.i32(UInt32(bytes.count))])
        guard let pointerVal = allocResult.first, case .i32(let pointer) = pointerVal else {
            throw ItoError.wasmTrap("Failed to allocate memory")
        }
        try self.writeMemory(offset: Int(pointer), bytes: bytes)
        return (Int32(bitPattern: pointer), Int32(bytes.count))
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

    // MARK: - Manga Exports

    /// Executes `get_search_manga_list(query: String, page: Int32, filters: [FilterStruct])`
    public func getSearchMangaList(query: String, page: Int32, filters: [FilterItem]?) async throws
        -> Manga.PageResult {
        return try await performSerialized {
            try self.callDecoding(
                Manga.PageResult.self, "get_search_manga_list",
                [.bytes(Array(query.utf8)), .int(page), .bytes(try self.postcardEncoder.encode(filters ?? []))])
        }
    }

    /// Executes `get_manga_list(listing: Listing, page: Int32)`
    public func getMangaList(listing: Listing, page: Int32) async throws -> Manga.PageResult {
        return try await performSerialized {
            try self.callDecoding(
                Manga.PageResult.self, "get_manga_list",
                [.bytes(try self.postcardEncoder.encode(listing)), .int(page)])
        }
    }

    /// Executes `get_manga_update(manga: Manga, needs_details: Bool, needs_chapters: Bool)`
    public func getMangaUpdate(manga: Manga, needsDetails: Bool = true, needsChapters: Bool = true)
        async throws -> Manga {
        return try await performSerialized {
            try self.callDecoding(
                Manga.self, "get_manga_update",
                [.bytes(try self.postcardEncoder.encode(manga)), .flag(needsDetails), .flag(needsChapters)])
        }
    }

    /// Executes `get_page_list(manga: Manga, chapter: Chapter)`
    public func getPageList(manga: Manga, chapter: Manga.Chapter) async throws -> [Page] {
        return try await performSerialized {
            try self.callDecoding(
                [Page].self, "get_page_list",
                [.bytes(try self.postcardEncoder.encode(manga)), .bytes(try self.postcardEncoder.encode(chapter))])
        }
    }

    // MARK: - Anime Exports

    /// Executes `get_search_anime_list(query: String, page: Int32, filters: [FilterStruct])`
    public func getSearchAnimeList(query: String, page: Int32, filters: [FilterItem]?) async throws
        -> Anime.PageResult {
        return try await performSerialized {
            try self.callDecoding(
                Anime.PageResult.self, "get_search_anime_list",
                [.bytes(Array(query.utf8)), .int(page), .bytes(try self.postcardEncoder.encode(filters ?? []))])
        }
    }

    /// Executes `get_anime_list(listing: Listing, page: Int32)`
    public func getAnimeList(listing: Listing, page: Int32) async throws -> Anime.PageResult {
        return try await performSerialized {
            try self.callDecoding(
                Anime.PageResult.self, "get_anime_list",
                [.bytes(try self.postcardEncoder.encode(listing)), .int(page)])
        }
    }

    /// Executes `get_anime_update(anime: Anime, needs_details: Bool, needs_episodes: Bool)`
    public func getAnimeUpdate(anime: Anime, needsDetails: Bool = true, needsEpisodes: Bool = true)
        async throws -> Anime {
        return try await performSerialized {
            try self.callDecoding(
                Anime.self, "get_anime_update",
                [.bytes(try self.postcardEncoder.encode(anime)), .flag(needsDetails), .flag(needsEpisodes)])
        }
    }

    /// Executes `get_video_list(anime: Anime, episode: Episode)`
    public func getVideoList(anime: Anime, episode: Anime.Episode) async throws -> [Anime.Video] {
        return try await performSerialized {
            try self.callDecoding(
                [Anime.Video].self, "get_video_list",
                [.bytes(try self.postcardEncoder.encode(anime)), .bytes(try self.postcardEncoder.encode(episode))])
        }
    }

    // MARK: - Novel Exports

    /// Executes `get_search_novel_list(query: String, page: Int32, filters: [FilterStruct])`
    public func getSearchNovelList(query: String, page: Int32, filters: [FilterItem]?) async throws
        -> Novel.PageResult {
        return try await performSerialized {
            try self.callDecoding(
                Novel.PageResult.self, "get_search_novel_list",
                [.bytes(Array(query.utf8)), .int(page), .bytes(try self.postcardEncoder.encode(filters ?? []))])
        }
    }

    /// Executes `get_novel_list(listing: Listing, page: Int32)`
    public func getNovelList(listing: Listing, page: Int32) async throws -> Novel.PageResult {
        return try await performSerialized {
            try self.callDecoding(
                Novel.PageResult.self, "get_novel_list",
                [.bytes(try self.postcardEncoder.encode(listing)), .int(page)])
        }
    }

    /// Executes `get_novel_update(novel: Novel, needs_details: Bool, needs_chapters: Bool)`
    public func getNovelUpdate(novel: Novel, needsDetails: Bool = true, needsChapters: Bool = true)
        async throws -> Novel {
        return try await performSerialized {
            try self.callDecoding(
                Novel.self, "get_novel_update",
                [.bytes(try self.postcardEncoder.encode(novel)), .flag(needsDetails), .flag(needsChapters)])
        }
    }

    /// Executes `get_chapter_content(novel: Novel, chapter: Chapter)`
    public func getChapterContent(novel: Novel, chapter: Novel.Chapter) async throws -> [Page] {
        return try await performSerialized {
            try self.callDecoding(
                [Page].self, "get_chapter_content",
                [.bytes(try self.postcardEncoder.encode(novel)), .bytes(try self.postcardEncoder.encode(chapter))])
        }
    }
}

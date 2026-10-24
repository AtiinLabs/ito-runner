import OSLog
import Foundation
import WasmKit

/// WasmBridge acts as the FFI layer connecting WasmKit's `Memory` to native Swift protocols
/// using the Postcard serialization format.
/// The runner owns its bridge; the bridge does not retain the actor.
/// Import callbacks retain codecs and use caller memory. Memory utility methods require a live runner.
public class WasmBridge {

    private weak var runner: ItoRunner?
    private let postcardEncoder: ItoPostcardEncoder
    private let postcardDecoder: ItoPostcardDecoder

    // Dependencies
    public var netModule: NetModule?
    public var htmlModule: HtmlModule?
    public var stdModule: StdModule?
    public var defaultsModule: DefaultsModule?
    public var envModule: EnvModule?
    public var webviewModule: WebviewModule?

    private var pendingNetResponseBytes: [UInt8]?
    private var pendingWebviewResponseBytes: [UInt8]?
    /// The export currently running, and the reason it reported for a failure.
    private var currentExport: String?
    private var reportedFailure: String?
    /// Cancellation of the job currently running, so host work it waits on can be cancelled.
    var activeCallToken: CallToken?
    /// How long host work may block a plugin call.
    var timeouts = HostCallTimeouts()

    public init(runner: ItoRunner) {
        self.runner = runner
        self.postcardEncoder = runner.postcardEncoder
        self.postcardDecoder = runner.postcardDecoder
    }

    /// Reads and decodes a Postcard struct from Wasm memory
    public func readRequest<T: Decodable>(_ type: T.Type, requestPtr: Int32, requestLen: Int32)
        async throws -> T {
        guard let runner else { throw ItoError.wasmTrap("Runner is no longer available") }
        let bytes = try await runner.readMemory(offset: Int(requestPtr), length: Int(requestLen))
        return try postcardDecoder.decode(type, from: bytes)
    }

    /// Encodes a Swift struct to Postcard and writes it to Wasm memory.
    /// Returns the packed (pointer << 32 | length) response.
    public func writeResponse<T: Encodable>(_ response: T) async throws -> Int64 {
        guard let runner else { throw ItoError.wasmTrap("Runner is no longer available") }
        let bytes = try postcardEncoder.encode(response)

        let allocResult = try await runner.executeExport("alloc", args: [.i32(UInt32(bytes.count))])
        guard let pointerVal = allocResult.first, case .i32(let pointer) = pointerVal else {
            throw ItoError.wasmTrap("Failed to allocate memory for response")
        }

        // Write the encoded bytes to the allocated pointer
        try await runner.writeMemory(offset: Int(pointer), bytes: bytes)

        // Pack pointer and length into Int64
        let packed = (UInt64(pointer) << 32) | UInt64(UInt32(bytes.count))
        return Int64(bitPattern: packed)
    }

    /// What the SDK prints for `Error::Unsupported`. An optional export (`handle_url`, `handle_image`)
    /// reporting it means "not handled", not a failure.
    static let unsupportedReason = "Unsupported operation"

    /// Starts tracking the failure the plugin reports while running `export`.
    func beginCall(_ export: String) {
        currentExport = export
        reportedFailure = nil
    }

    /// The failure the plugin reported since `beginCall(_:)`, if any. Clears it.
    func takeReportedFailure() -> String? {
        defer { reportedFailure = nil }
        return reportedFailure
    }

    /// The SDK prints its failure line right before an export returns 0, so the last print of a
    /// call decides: an SDK failure line for the running export sets the reason, anything else
    /// (the plugin's own logging) clears it.
    private func recordPrint(_ message: String) {
        guard let export = currentExport else { return }
        reportedFailure = Self.failureReason(printed: message, export: export)
    }

    /// The reason in a line the SDK prints before `export` returns 0:
    /// - "Error in <export>: <reason>" for a failed call (the reason is returned);
    /// - "Deserialization error: …", "Postcard decoding error in <export>: …" when the plugin
    ///   couldn't read its arguments, "Serialization error: …" when it couldn't encode its result
    ///   (the whole line is returned).
    static func failureReason(printed message: String, export: String) -> String? {
        let failurePrefix = "Error in \(export): "
        if message.hasPrefix(failurePrefix) {
            return String(message.dropFirst(failurePrefix.count))
        }
        if message.hasPrefix("Deserialization error: ")
            || message.hasPrefix("Serialization error: ")
            || message.hasPrefix("Postcard decoding error in \(export): ") {
            return message
        }
        return nil
    }

    /// How a failed webview host call reaches the caller: typed errors as they are, anything else
    /// as a webview host-module error.
    static func webviewError(_ error: Error) -> ItoError {
        if let error = error as? ItoError { return error }
        return .hostModuleError(domain: "webview", message: error.localizedDescription)
    }

    /// Runs a plugin's network request on the net module and waits for it. A failure, a
    /// cancelled call or a request past the watchdog deadline reaches the plugin as a 500
    /// response it handles like any server error, so its export finishes normally.
    func fetchForPlugin(_ request: NetRequest, options: NetOptions?, label: String) -> NetResponse {
        let module = netModule
        let outcome = waitForHostWork(timeout: timeouts.net) { () async throws -> NetResponse in
            guard let module else {
                throw ItoError.hostModuleError(domain: "net", message: "NetModule not provided")
            }
            if let options {
                return try await module.fetch(request: request, options: options)
            }
            return try await module.fetch(request: request)
        }
        let failure: String
        switch outcome {
        case .completed(let response):
            return Self.withoutTransportErrorHeader(response)
        case .failed(let error):
            failure = error.localizedDescription
        case .cancelled:
            failure = "The request was cancelled."
        case .timedOut:
            failure = "The request timed out."
        }
        // Plugins from before the header see the same 500 as always; newer SDKs read the header
        // to tell "couldn't reach the server" from a server error.
        return NetResponse(
            status: 500,
            headers: [
                "Content-Type": "text/plain",
                Self.transportErrorHeader: failure.components(separatedBy: .newlines).joined(separator: " ")
            ],
            body: Array("FFI Error in \(label): \(failure)".utf8)
        )
    }

    /// The header a host's 500 response carries when the request never reached the server
    /// (no connection, cancelled, timed out). Only the host sets it: a server's own is removed.
    public static let transportErrorHeader = "X-Ito-Transport-Error"

    /// `response` without a transport-error header a server sent, which would make the plugin
    /// think its request never arrived.
    private static func withoutTransportErrorHeader(_ response: NetResponse) -> NetResponse {
        let spoofed = response.headers.keys.filter {
            $0.caseInsensitiveCompare(transportErrorHeader) == .orderedSame
        }
        guard !spoofed.isEmpty else { return response }
        var headers = response.headers
        spoofed.forEach { headers[$0] = nil }
        return NetResponse(status: response.status, headers: headers, body: response.body)
    }

    /// Runs a web view operation and waits for it. Returns nil when the call was cancelled: the
    /// plugin then gets an empty result it handles as an error and unwinds normally, where a
    /// thrown error would abort it mid-call. Throws on failure or timeout.
    func webviewForPlugin<Value: Sendable>(
        _ work: @escaping @Sendable (any WebviewModule) async throws -> Value
    ) throws -> Value? {
        let module = webviewModule
        let outcome = waitForHostWork(timeout: timeouts.webview) { () async throws -> Value in
            guard let module else {
                throw ItoError.hostModuleError(domain: "webview", message: "WebviewModule not provided")
            }
            return try await work(module)
        }
        switch outcome {
        case .completed(let value):
            return value
        case .failed(let error):
            RunnerLogger.bridge.error("WasmBridge: webview call failed: \(error.localizedDescription)")
            throw Self.webviewError(error)
        case .cancelled:
            return nil
        case .timedOut:
            throw ItoError.hostModuleError(domain: "webview", message: "The page took too long to respond.")
        }
    }

    // MARK: - Imports Registration

    /// The host functions a plugin can import.
    public func buildImports(store: Store) -> Imports {
        Self.imports(from: buildImportTable(store: store))
    }

    static func imports(from table: [String: [String: Function]]) -> Imports {
        var imports = Imports()
        for (module, functions) in table {
            for (name, function) in functions {
                imports.define(module: module, name: name, function)
            }
        }
        return imports
    }

    /// The host functions a plugin can import, by module and name. The one list of what this
    /// host provides: imports are built from it and plugins are checked against it.
    func buildImportTable(store: Store) -> [String: [String: Function]] {
        // --- ito:core/net ---
        let netFetch = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            let requestBytes = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                Array(buffer)
            }

            let request: NetRequest
            do {
                request = try self.postcardDecoder.decode(NetRequest.self, from: requestBytes)
            } catch {
                throw ItoError.wasmTrap("Failed to decode NetRequest: \(error)")
            }
            let response = self.fetchForPlugin(request, options: nil, label: "net_fetch")
            do {
                let responseBytes = try self.postcardEncoder.encode(response)
                self.pendingNetResponseBytes = responseBytes
                return [.i32(UInt32(responseBytes.count))]
            } catch {
                throw ItoError.wasmTrap("Failed to serialize NetResponse: \(error)")
            }
        }

        let netFetchV2 = Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i32]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32
            let optPtr = args[2].i32
            let optLen = args[3].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            let requestBytes = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in Array(buffer) }

            let optBytes = memory.withUnsafeMutableBufferPointer(
                offset: UInt(optPtr), count: Int(optLen)
            ) { buffer in Array(buffer) }

            let request: NetRequest
            let options: NetOptions
            do {
                request = try self.postcardDecoder.decode(NetRequest.self, from: requestBytes)
                options = try self.postcardDecoder.decode(NetOptions.self, from: optBytes)
            } catch {
                throw ItoError.wasmTrap("Failed to decode NetRequest: \(error)")
            }
            let response = self.fetchForPlugin(request, options: options, label: "net_fetch_v2")
            do {
                let responseBytes = try self.postcardEncoder.encode(response)
                self.pendingNetResponseBytes = responseBytes
                return [.i32(UInt32(responseBytes.count))]
            } catch {
                throw ItoError.wasmTrap("Failed to serialize NetResponse: \(error)")
            }
        }

        let netFetchRead = Function(store: store, parameters: [.i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let destPtr = args[0].i32

            guard let bytes = self.pendingNetResponseBytes else {
                throw ItoError.wasmTrap("fetch_read called but no pending response bytes exist")
            }
            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            memory.withUnsafeMutableBufferPointer(
                offset: UInt(destPtr), count: bytes.count
            ) { buffer in
                bytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            self.pendingNetResponseBytes = nil
            return []
        }

        let htmlParse = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            let htmlString = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            let elementId = try module.parse(html: htmlString)
            // RunnerLogger.bridge.debug("WasmBridge HtmlParse returning: \(elementId)")
            return [.i32(elementId)]
        }

        let htmlSelect = Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32
            let requestPtr = args[1].i32
            let requestLen = args[2].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                throw ItoError.wasmTrap("Plugin must export memory and alloc")
            }

            let selectorString = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            // RunnerLogger.bridge.debug("\("WasmBridge HtmlSelect(id: \(elementId)"), selector: '\(selectorString)')")
            let resultIds = try module.select(elementId: elementId, selector: selectorString)
            let resultInt32s = resultIds.map { Int32(bitPattern: $0) }
            let responseBytes = try self.postcardEncoder.encode(resultInt32s)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let htmlText = Function(store: store, parameters: [.i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let alloc = caller.instance?.exports[function: "alloc"]
            else {
                throw ItoError.wasmTrap("Plugin must export alloc")
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            // RunnerLogger.bridge.debug("\("WasmBridge HtmlText(id: \(elementId)"))")
            let text = try module.text(elementId: elementId)
            let responseBytes = try self.postcardEncoder.encode(text)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let htmlAttr = Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32
            let requestPtr = args[1].i32
            let requestLen = args[2].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                throw ItoError.wasmTrap("Plugin must export memory and alloc")
            }

            let attrName = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            // RunnerLogger.bridge.debug("\("WasmBridge HtmlAttr(id: \(elementId)"), name: '\(attrName)')")
            let attrVal = try module.attr(elementId: elementId, name: attrName)
            var responseBytes: [UInt8] = []
            if let val = attrVal {
                responseBytes.append(1)  // Option::Some
                responseBytes.append(contentsOf: try self.postcardEncoder.encode(val))
            } else {
                responseBytes.append(0)  // Option::None
            }

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let htmlFree = Function(store: store, parameters: [.i32], results: []) {
            [weak self] _, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            // RunnerLogger.bridge.debug("\("WasmBridge HtmlFree(id: \(elementId)"))")
            module.free(elementId: elementId)
            return []
        }

        let htmlOwnText = Function(store: store, parameters: [.i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let alloc = caller.instance?.exports[function: "alloc"] else { throw ItoError.wasmTrap("Plugin must export alloc") }
            guard let module = self.htmlModule else { throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided") }

            let text = try module.ownText(elementId: elementId)
            let responseBytes = try self.postcardEncoder.encode(text)
            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else { throw ItoError.wasmTrap("Memory lost after alloc") }
            refetchedMemory.withUnsafeMutableBufferPointer(offset: UInt(responsePtr), count: responseBytes.count) { buffer in
                responseBytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(src)) }
            }
            return [.i64((UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count)))]
        }

        let htmlHtmlContent = Function(store: store, parameters: [.i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let alloc = caller.instance?.exports[function: "alloc"] else { throw ItoError.wasmTrap("Plugin must export alloc") }
            guard let module = self.htmlModule else { throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided") }

            let text = try module.html(elementId: elementId)
            let responseBytes = try self.postcardEncoder.encode(text)
            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else { throw ItoError.wasmTrap("Memory lost after alloc") }
            refetchedMemory.withUnsafeMutableBufferPointer(offset: UInt(responsePtr), count: responseBytes.count) { buffer in
                responseBytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(src)) }
            }
            return [.i64((UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count)))]
        }

        let htmlOuterHtml = Function(store: store, parameters: [.i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let alloc = caller.instance?.exports[function: "alloc"] else { throw ItoError.wasmTrap("Plugin must export alloc") }
            guard let module = self.htmlModule else { throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided") }

            let text = try module.outerHtml(elementId: elementId)
            let responseBytes = try self.postcardEncoder.encode(text)
            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else { throw ItoError.wasmTrap("Memory lost after alloc") }
            refetchedMemory.withUnsafeMutableBufferPointer(offset: UInt(responsePtr), count: responseBytes.count) { buffer in
                responseBytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(src)) }
            }
            return [.i64((UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count)))]
        }

        let stdprint = Function(store: store, parameters: [.i32, .i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export memory")
            }

            let string = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            self.recordPrint(string)

            guard let module = self.stdModule else {
                throw ItoError.hostModuleError(domain: "std", message: "StdModule not provided")
            }

            module.print(message: string)
            return []
        }

        let defaultsSet = Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let keyPtr = args[0].i32
            let keyLen = args[1].i32
            let valPtr = args[2].i32
            let valLen = args[3].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export memory")
            }

            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(keyPtr), count: Int(keyLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            let val = memory.withUnsafeMutableBufferPointer(
                offset: UInt(valPtr), count: Int(valLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }

            module.set(key: key, value: val)
            return []
        }

        let defaultsGet = Function(store: store, parameters: [.i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let keyPtr = args[0].i32
            let keyLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                throw ItoError.wasmTrap("Plugin must export memory and alloc")
            }

            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(keyPtr), count: Int(keyLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }

            let val = module.get(key: key)
            var responseBytes: [UInt8] = []
            if let v = val {
                responseBytes.append(1)  // Option::Some
                responseBytes.append(contentsOf: try self.postcardEncoder.encode(v))
            } else {
                responseBytes.append(0)  // Option::None
            }

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let defaultsRemove = Function(store: store, parameters: [.i32, .i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let keyPtr = args[0].i32
            let keyLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export memory")
            }

            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(keyPtr), count: Int(keyLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }

            module.remove(key: key)
            return []
        }

        let envGetLanguages = Function(store: store, parameters: [], results: [.i64]) {
            [weak self] caller, _ in
            guard let self = self else { return [] }

            guard let alloc = caller.instance?.exports[function: "alloc"]
            else {
                throw ItoError.wasmTrap("Plugin must export alloc")
            }

            let langs = self.envModule?.getLanguages() ?? ["en"]
            let responseBytes = try self.postcardEncoder.encode(langs)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let webviewLoadUrl = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            let requestBytes = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in Array(buffer) }

            let request: WebviewRequest
            do {
                request = try self.postcardDecoder.decode(WebviewRequest.self, from: requestBytes)
            } catch {
                throw ItoError.wasmTrap("Failed to decode WebviewRequest: \(error)")
            }

            guard let response = try self.webviewForPlugin({ module in
                try await module.loadUrl(request: request)
            }) else { return [.i32(0)] }
            let responseBytes = try self.postcardEncoder.encode(response)
            self.pendingWebviewResponseBytes = responseBytes
            return [.i32(UInt32(responseBytes.count))]
        }

        let webviewExecuteJs = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            let scriptString = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in String(decoding: buffer, as: UTF8.self) }

            guard let result = try self.webviewForPlugin({ module in
                try await module.executeJs(script: scriptString)
            }) else { return [.i32(0)] }
            let responseBytes = Array(result.utf8)
            self.pendingWebviewResponseBytes = responseBytes
            return [.i32(UInt32(responseBytes.count))]
        }

        let webviewReadResult = Function(store: store, parameters: [.i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let destPtr = args[0].i32

            guard let bytes = self.pendingWebviewResponseBytes else {
                throw ItoError.wasmTrap("webview_read_result called but no pending response bytes exist")
            }
            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export linear memory")
            }

            memory.withUnsafeMutableBufferPointer(offset: UInt(destPtr), count: bytes.count) { buffer in
                bytes.withUnsafeBytes { src in buffer.copyMemory(from: UnsafeRawBufferPointer(src)) }
            }

            self.pendingWebviewResponseBytes = nil
            return []
        }

        return [
            "ito:core/net": [
                "fetch": netFetch,
                "fetch_v2": netFetchV2,
                "fetch_read": netFetchRead
            ],
            "ito:core/html": [
                "parse": htmlParse,
                "select": htmlSelect,
                "text": htmlText,
                "attr": htmlAttr,
                "free": htmlFree,
                "own_text": htmlOwnText,
                "html_content": htmlHtmlContent,
                "outer_html": htmlOuterHtml
            ],
            "ito:core/std": ["print": stdprint],
            "ito:core/defaults": [
                "set": defaultsSet,
                "get": defaultsGet,
                "remove": defaultsRemove
            ],
            "ito:core/env": [
                "get_languages": envGetLanguages
            ],
            "ito:core/webview": [
                "webview_load_url": webviewLoadUrl,
                "webview_execute_js": webviewExecuteJs,
                "webview_read_result": webviewReadResult
            ]
        ]
    }
}

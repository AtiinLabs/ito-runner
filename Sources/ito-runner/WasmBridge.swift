import OSLog
import Foundation
import WasmKit

/// WasmBridge acts as the FFI layer connecting WasmKit's `Memory` to native Swift protocols
/// using the Postcard serialization format.
/// The runner owns its bridge; the bridge holds no reference to the runner.
/// Import callbacks retain codecs and use caller memory.
public class WasmBridge {

    /// Host-module payloads are laid out for the supported ABI.
    private let postcardEncoder = ItoPostcardEncoder(abiVersion: sharedLayoutABIVersion)
    private let postcardDecoder = ItoPostcardDecoder(abiVersion: sharedLayoutABIVersion)

    // Dependencies
    var netModule: NetModule?
    var htmlModule: HtmlModule?
    var stdModule: StdModule?
    var defaultsModule: DefaultsModule?
    var envModule: EnvModule?
    var webviewModule: WebviewModule?

    private var pendingNetResponseBytes: [UInt8]?
    private var pendingWebviewResponseBytes: [UInt8]?
    /// The export currently running, and the reason it reported for a failure.
    private var currentExport: String?
    private var reportedFailure: String?
    /// Cancellation of the job currently running, so host work it waits on can be cancelled.
    var activeCallToken: CallToken?
    /// How long host work may block a plugin call.
    var timeouts = HostCallTimeouts()

    /// Queue-confined per-export buffers must not survive a cancellation, trap or account switch.
    func clearOperationState() {
        pendingNetResponseBytes = nil
        pendingWebviewResponseBytes = nil
        currentExport = nil
        reportedFailure = nil
    }

    /// True when no per-export buffer or failure tracking is left from an earlier call.
    var operationStateIsClear: Bool {
        pendingNetResponseBytes == nil && pendingWebviewResponseBytes == nil
            && currentExport == nil && reportedFailure == nil
    }

    public init() {}

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

    /// Whether a plugin's network call may start: the call it runs for, or the transport failure
    /// text it gets instead.
    private enum NetAdmission {
        case admitted(CallToken)
        case refused(String)
    }

    /// Checked before any network work starts, by a single request and by a batch alike.
    private func netAdmission() -> NetAdmission {
        guard let token = activeCallToken else { return .refused(Self.missingContextText) }
        if token.terminalOutcome != nil { return .refused(Self.admissionRefusedText) }
        return .admitted(token)
    }

    /// Runs a plugin's network request on the net module and waits for it. A failure, a
    /// cancelled call or a request past the watchdog deadline reaches the plugin as a 500
    /// response it handles like any server error, so its export finishes normally. A request past
    /// the deadline is also recorded on the call, which then reports `hostCallTimedOut(.net)`.
    func fetchForPlugin(_ request: NetRequest, label: String) -> NetResponse {
        let token: CallToken
        switch netAdmission() {
        case .refused(let failure):
            return Self.transportFailure(failure, label: label, includeBody: false)
        case .admitted(let admitted):
            token = admitted
        }
        let context = token.context
        let module = netModule
        let outcome = waitForHostWork(token: token, timeout: timeouts.net) { () async throws -> NetResponse in
            guard let module else {
                throw ItoError.hostModuleError(domain: "net", message: "NetModule not provided")
            }
            return try await module.fetch(request: request, context: context)
        }
        Self.record(outcome, on: token)
        return Self.netResponse(for: outcome, label: label)
    }

    /// Records on the call what an outcome decided: a policy refusal, or a watchdog deadline that
    /// settled the host call. A result that arrived first won the cell and records nothing.
    private static func record<Value>(_ outcome: HostCallOutcome<Value>, on token: CallToken) {
        switch outcome {
        case .failed(let error):
            if let policy = policyOutcome(error) { token.recordPolicyOutcome(policy) }
        case .timedOut:
            token.recordHostCallTimeout(.net)
        case .completed, .cancelled:
            break
        }
    }

    /// What the plugin sees for one request's outcome.
    private static func netResponse(for outcome: HostCallOutcome<NetResponse>, label: String) -> NetResponse {
        let failure: String
        switch outcome {
        case .completed(let response):
            return withoutTransportErrorHeader(response)
        case .failed(let error):
            failure = policyOutcome(error) != nil ? admissionRefusedText : guestFailureText(for: error)
        case .cancelled:
            failure = cancelledText
        case .timedOut:
            failure = timedOutText
        }
        return transportFailure(failure, label: label, includeBody: true)
    }

    /// The most requests one `fetch_batch` call carries. Part of the import's contract with the
    /// SDK, which chunks to this size.
    static let maxBatch = 4
    /// The most response body bytes one `fetch_batch` call returns, in total.
    static let batchResponseBudget = 32 * 1024 * 1024
    static let batchLabel = "net_fetch_batch"
    /// Methods a batch sends. Requests in a batch run concurrently, so only ones a retry or a
    /// reordering can't hurt are allowed.
    private static let batchMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]

    static func isBatchMethod(_ method: String) -> Bool {
        batchMethods.contains(method.uppercased())
    }

    /// Runs a plugin's safe requests concurrently on the net module under one wait and one
    /// deadline, so the call's single cancel action cancels every one of them. Result `i` answers
    /// request `i`. Each request ends as `fetchForPlugin` would end it, except that a policy
    /// refusal is recorded by the request that met it as soon as it happens and cancels the rest,
    /// which then report the refusal too.
    func fetchBatchForPlugin(_ requests: [NetRequest]) -> [NetResponse] {
        let token: CallToken
        switch netAdmission() {
        case .refused(let failure):
            let response = Self.transportFailure(failure, label: Self.batchLabel, includeBody: false)
            return Array(repeating: response, count: requests.count)
        case .admitted(let admitted):
            token = admitted
        }
        let sent = requests.filter { Self.isBatchMethod($0.method) }
        guard !sent.isEmpty else {
            return Self.batchResponses(for: requests, outcomes: [])
        }
        let context = token.context
        let module = netModule
        let outcome = waitForHostWork(token: token, timeout: timeouts.net) {
            () async -> [HostCallOutcome<NetResponse>] in
            guard let module else {
                let missing = ItoError.hostModuleError(domain: "net", message: "NetModule not provided")
                return Array(repeating: .failed(missing), count: sent.count)
            }
            return await withTaskGroup(of: (Int, HostCallOutcome<NetResponse>).self) { group in
                for (index, request) in sent.enumerated() {
                    group.addTask {
                        do {
                            return (index, .completed(try await module.fetch(request: request, context: context)))
                        } catch is CancellationError {
                            return (index, .cancelled)
                        } catch {
                            if let policy = Self.policyOutcome(error) { token.recordPolicyOutcome(policy) }
                            return (index, .failed(error))
                        }
                    }
                }
                var results = [HostCallOutcome<NetResponse>?](repeating: nil, count: sent.count)
                for await (index, result) in group {
                    results[index] = result
                    if case .failed(let error) = result, Self.policyOutcome(error) != nil {
                        group.cancelAll()
                    }
                }
                return results.map { $0 ?? .cancelled }
            }
        }
        Self.record(outcome, on: token)
        let outcomes: [HostCallOutcome<NetResponse>]
        switch outcome {
        case .completed(let results): outcomes = results
        case .failed(let error): outcomes = Array(repeating: .failed(error), count: sent.count)
        case .cancelled: outcomes = Array(repeating: .cancelled, count: sent.count)
        case .timedOut: outcomes = Array(repeating: .timedOut, count: sent.count)
        }
        return Self.batchResponses(for: requests, outcomes: outcomes)
    }

    /// The plugin's answers to a batch. `outcomes` are the outcomes of the requests that were
    /// sent, in order; the rest were refused for their method and get a transport failure. After
    /// a policy refusal every request that didn't complete reports it, however it ended. Bodies
    /// are admitted in request order up to `budget`: a response that would pass it becomes a
    /// transport failure the SDK retries on its own.
    static func batchResponses(
        for requests: [NetRequest], outcomes: [HostCallOutcome<NetResponse>],
        budget: Int = batchResponseBudget
    ) -> [NetResponse] {
        let refused = outcomes.contains { outcome in
            if case .failed(let error) = outcome { return policyOutcome(error) != nil }
            return false
        }
        var remaining = outcomes.makeIterator()
        var admitted = 0
        return requests.map { request in
            guard isBatchMethod(request.method), let outcome = remaining.next() else {
                return transportFailure(unsafeMethodText, label: batchLabel, includeBody: true)
            }
            let response: NetResponse
            if refused, !outcome.isCompleted {
                response = transportFailure(admissionRefusedText, label: batchLabel, includeBody: true)
            } else {
                response = netResponse(for: outcome, label: batchLabel)
            }
            guard response.body.count <= budget - admitted else {
                return transportFailure(batchBudgetText, label: batchLabel, includeBody: true)
            }
            admitted += response.body.count
            return response
        }
    }

    /// The length a net import returns for `count` payload bytes, or nil when it doesn't fit the
    /// positive `Int32` range the plugin reads it in.
    static func returnedLength(count: Int) -> UInt32? {
        guard count > 0, count <= Int(Int32.max) else { return nil }
        return UInt32(count)
    }

    /// Encodes one response for `fetch_read` and returns the length to give the plugin. A response
    /// too large to report becomes a transport failure instead.
    private func publish(_ response: NetResponse, label: String) throws -> UInt32 {
        var bytes = try postcardEncoder.encode(response)
        var length = Self.returnedLength(count: bytes.count)
        if length == nil {
            let failure = Self.transportFailure(Self.responseTooLargeText, label: label, includeBody: true)
            bytes = try postcardEncoder.encode(failure)
            length = Self.returnedLength(count: bytes.count)
        }
        guard let length else { throw ItoError.wasmTrap("Failed to serialize NetResponse: empty payload") }
        pendingNetResponseBytes = bytes
        return length
    }

    /// Encodes a batch's responses for `fetch_read` and returns the length to give the plugin. A
    /// batch too large to report is answered with the budget failure for every request.
    private func publish(batch responses: [NetResponse]) throws -> UInt32 {
        var bytes = try postcardEncoder.encode(responses)
        var length = Self.returnedLength(count: bytes.count)
        if length == nil {
            let failure = Self.transportFailure(Self.batchBudgetText, label: Self.batchLabel, includeBody: true)
            bytes = try postcardEncoder.encode(Array(repeating: failure, count: responses.count))
            length = Self.returnedLength(count: bytes.count)
        }
        guard let length else { throw ItoError.wasmTrap("Failed to serialize NetResponse: empty payload") }
        pendingNetResponseBytes = bytes
        return length
    }

    // Everything below reaches guest memory. Fixed ASCII English only: never localized, never
    // derived from host error text, which can carry URLs, tokens or cookies.
    static let missingContextText = "Missing host context"
    static let admissionRefusedText = "Host admission refused"
    static let genericFailureText = "Host network request failed."
    static let cancelledText = "The request was cancelled."
    static let timedOutText = "The request timed out."
    static let unsafeMethodText = "Only GET, HEAD and OPTIONS requests can be batched."
    /// The reason the SDK looks for to retry a batch element on its own. Never change it.
    static let batchBudgetText = "batch response budget exceeded"
    static let responseTooLargeText = "The response was too large."

    /// Specific guest texts for the `URLError` codes a plugin can usefully distinguish.
    static let urlErrorTexts: [URLError.Code: String] = [
        .notConnectedToInternet: "No network connection.",
        .cannotFindHost: "Cannot find the host.",
        .dnsLookupFailed: "Cannot find the host.",
        .cannotConnectToHost: "Cannot connect to the host.",
        .secureConnectionFailed: "Secure connection failed.",
        .serverCertificateUntrusted: "Secure connection failed.",
        .serverCertificateHasBadDate: "Secure connection failed.",
        .serverCertificateHasUnknownRoot: "Secure connection failed.",
        .serverCertificateNotYetValid: "Secure connection failed.",
        .timedOut: timedOutText,
        .cancelled: cancelledText
    ]

    /// The guest text for a host failure: a fixed text for an allowlisted `URLError`, otherwise the
    /// generic one.
    static func guestFailureText(for error: any Error) -> String {
        guard let code = (error as? URLError)?.code else { return genericFailureText }
        return urlErrorTexts[code] ?? genericFailureText
    }

    private static func transportFailure(_ failure: String, label: String, includeBody: Bool) -> NetResponse {
        // Plugins from before the header see the same 500 as always; newer SDKs read the header
        // to tell "couldn't reach the server" from a server error.
        NetResponse(
            status: 500,
            headers: [
                "Content-Type": "text/plain",
                transportErrorHeader: failure
            ],
            body: includeBody ? Array("FFI Error in \(label): \(failure)".utf8) : []
        )
    }

    private static func policyOutcome(_ error: any Error) -> HostNetworkPolicyOutcome? {
        if let outcome = error as? HostNetworkPolicyOutcome { return outcome }
        if let error = error as? ItoError, case .networkPolicy(let outcome) = error { return outcome }
        return nil
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

    /// The length a web view import returns when there is no result (the call was cancelled).
    /// Negative as the plugin reads it, so a zero length can mean an empty result: a script that
    /// evaluates to nothing. SDK versions before 0.2.1 treat zero as no result too.
    static let noWebviewResult = UInt32(bitPattern: -1)

    /// Runs a web view operation and waits for it. Returns nil when the call was cancelled, the
    /// host refused it by policy or it outlived the watchdog deadline: the plugin then gets
    /// `noWebviewResult` it handles as an error and unwinds normally, where a thrown error would
    /// abort it mid-call. The outer caller still receives the recorded outcome. Throws on failure.
    func webviewForPlugin<Value: Sendable>(
        _ work: @escaping @Sendable (any WebviewModule, NetworkOperationContext) async throws -> Value
    ) throws -> Value? {
        guard let token = activeCallToken else {
            throw ItoError.hostModuleError(domain: "webview", message: Self.missingContextText)
        }
        if token.terminalOutcome != nil { return nil }
        let context = token.context
        let module = webviewModule
        let outcome = waitForHostWork(token: token, timeout: timeouts.webview) { () async throws -> Value in
            guard let module else {
                throw ItoError.hostModuleError(domain: "webview", message: "WebviewModule not provided")
            }
            return try await work(module, context)
        }
        switch outcome {
        case .completed(let value):
            return value
        case .failed(let error):
            if let policy = Self.policyOutcome(error) {
                token.recordPolicyOutcome(policy)
                return nil
            }
            throw Self.webviewError(error)
        case .cancelled:
            return nil
        case .timedOut:
            token.recordHostCallTimeout(.webview)
            return nil
        }
    }

    // MARK: - Imports Registration

    /// The host functions a plugin can import.
    func buildImports(store: Store) -> Imports {
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
            let response = self.fetchForPlugin(request, label: "net_fetch")
            do {
                return [.i32(try self.publish(response, label: "net_fetch"))]
            } catch {
                throw ItoError.wasmTrap("Failed to serialize NetResponse: \(error)")
            }
        }

        // The options argument is reserved (the SDK's `NetOptions`): no host acts on it, so it is
        // not read.
        let netFetchV2 = Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [.i32]) {
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

            let request: NetRequest
            do {
                request = try self.postcardDecoder.decode(NetRequest.self, from: requestBytes)
            } catch {
                throw ItoError.wasmTrap("Failed to decode NetRequest: \(error)")
            }
            let response = self.fetchForPlugin(request, label: "net_fetch_v2")
            do {
                return [.i32(try self.publish(response, label: "net_fetch_v2"))]
            } catch {
                throw ItoError.wasmTrap("Failed to serialize NetResponse: \(error)")
            }
        }

        // Up to `maxBatch` safe requests run concurrently. The plugin reads the postcard
        // `Vec<NetResponse>` with `fetch_read`, as for `fetch_v2`; result `i` answers request `i`.
        let netFetchBatch = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
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

            let requests: [NetRequest]
            do {
                requests = try self.postcardDecoder.decode([NetRequest].self, from: requestBytes)
            } catch {
                throw ItoError.wasmTrap("Failed to decode NetRequest batch: \(error)")
            }
            guard (1...Self.maxBatch).contains(requests.count) else {
                throw ItoError.wasmTrap("fetch_batch takes 1 to \(Self.maxBatch) requests, got \(requests.count)")
            }
            let responses = self.fetchBatchForPlugin(requests)
            do {
                return [.i32(try self.publish(batch: responses))]
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

        let defaultsSet = defaultsWrite(store: store) { module, key, value in
            module.set(key: key, value: value)
        }
        let defaultsSetSecret = defaultsWrite(store: store) { module, key, value in
            module.setSecret(key: key, value: value)
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

            guard let response = try self.webviewForPlugin({ module, context in
                try await module.loadUrl(request: request, context: context)
            }) else { return [.i32(Self.noWebviewResult)] }
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

            guard let result = try self.webviewForPlugin({ module, context in
                try await module.executeJs(script: scriptString, context: context)
            }) else { return [.i32(Self.noWebviewResult)] }
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
                "fetch_batch": netFetchBatch,
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
                "remove": defaultsRemove,
                "set_secret": defaultsSetSecret
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

    /// A `(key, value)` defaults import: reads both strings from the plugin's memory and hands
    /// them to `write` with the defaults module.
    private func defaultsWrite(
        store: Store,
        _ write: @escaping (any DefaultsModule, String, String) -> Void
    ) -> Function {
        Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            guard let memory = caller.instance?.exports[memory: "memory"] else {
                throw ItoError.wasmTrap("Plugin must export memory")
            }
            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(args[0].i32), count: Int(args[1].i32)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }
            let value = memory.withUnsafeMutableBufferPointer(
                offset: UInt(args[2].i32), count: Int(args[3].i32)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }
            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }
            write(module, key, value)
            return []
        }
    }
}

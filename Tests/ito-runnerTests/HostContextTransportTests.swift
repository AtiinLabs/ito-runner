import Foundation
import Testing
import WAT
@testable import ito_runner

private actor ContextWebview: WebviewModule {
    private(set) var loads: [NetworkOperationContext] = []
    private(set) var scripts: [NetworkOperationContext] = []
    let denied: Bool

    init(denied: Bool) { self.denied = denied }
    func loadUrl(request: WebviewRequest, context: NetworkOperationContext) async throws -> WebviewResponse {
        loads.append(context)
        if denied { throw HostNetworkPolicyOutcome.foregroundPermissionRequired }
        return WebviewResponse(url: request.url, html: "")
    }
    func executeJs(script: String, context: NetworkOperationContext) async throws -> String {
        scripts.append(context)
        if denied { throw HostNetworkPolicyOutcome.hardUserBlocked }
        return ""
    }
}

/// What the guest side of a probe saw, in order. Written on the runner's queue, read after.
private final class GuestObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private struct FailingNet: NetModule {
    let error: any Error
    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        throw error
    }
}

private extension ItoRunner {
    func transportProbe(_ request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        let bridge = self.bridge
        return try await performSerialized(context: context) {
            guard let bridge else { throw ItoError.wasmTrap("No loaded bridge") }
            return bridge.fetchForPlugin(request, label: "test")
        }
    }

    /// Two web view calls the way a guest makes them, swallowing whatever it is told.
    func webviewProbe(context: NetworkOperationContext, saw: GuestObservations) async throws -> Bool {
        let bridge = self.bridge
        return try await performSerialized(context: context) {
            guard let bridge else { throw ItoError.wasmTrap("No loaded bridge") }
            let load = try bridge.webviewForPlugin { module, context in
                try await module.loadUrl(request: WebviewRequest(url: "http://x", script: nil), context: context)
            }
            saw.record(load == nil ? "load: no result" : "load: result")
            let script = try bridge.webviewForPlugin { module, context in
                try await module.executeJs(script: "next", context: context)
            }
            saw.record(script == nil ? "script: no result" : "script: result")
            return true
        }
    }

    /// A net request, then a web view load, in one export.
    func netThenWebviewProbe(_ request: NetRequest, context: NetworkOperationContext,
                             saw: GuestObservations) async throws -> Bool {
        let bridge = self.bridge
        return try await performSerialized(context: context) {
            guard let bridge else { throw ItoError.wasmTrap("No loaded bridge") }
            saw.record("net: \(bridge.fetchForPlugin(request, label: "test").status)")
            let load = try bridge.webviewForPlugin { module, context in
                try await module.loadUrl(request: WebviewRequest(url: "http://x", script: nil), context: context)
            }
            saw.record(load == nil ? "load: no result" : "load: result")
            return true
        }
    }
}

@Suite("Host transport context boundaries", .timeLimit(.minutes(1)))
struct HostContextTransportTests {
    private let request = NetRequest(url: "http://x", method: "GET", headers: ["purpose": "interactive"], body: nil)
    private func runner(net: (any NetModule)? = nil, webview: (any WebviewModule)? = nil,
                        timeouts: HostCallTimeouts = HostCallTimeouts()) async throws -> ItoRunner {
        let runner = ItoRunner()
        if let net { await runner.setNetModule(net) }
        if let webview { await runner.setWebviewModule(webview) }
        await runner.setHostCallTimeouts(timeouts)
        try await runner.loadPlugin(fromBytes: wat2wasm("(module (memory (export \"memory\") 1))"))
        return runner
    }

    @Test func theWebviewModuleReceivesTheCallsExactContext() async throws {
        let webview = ContextWebview(denied: false)
        let runner = try await runner(webview: webview)
        let context = NetworkOperationContext.test
        let saw = GuestObservations()
        #expect(try await runner.webviewProbe(context: context, saw: saw))
        #expect(await webview.loads == [context])
        #expect(await webview.scripts == [context])
        #expect(saw.all == ["load: result", "script: result"])
    }

    /// A refused web view launch gives the guest the no-result value, as cancellation does, rather
    /// than throwing mid-call. Later guest calls are refused without reaching the module. The
    /// caller still gets the policy outcome.
    @Test func aDeniedWebviewCallGivesTheGuestNoResultAndTheCallerThePolicyOutcome() async throws {
        let webview = ContextWebview(denied: true)
        let runner = try await runner(webview: webview)
        let saw = GuestObservations()
        await #expect(throws: ItoError.networkPolicy(.foregroundPermissionRequired)) {
            try await runner.webviewProbe(context: .test, saw: saw)
        }
        #expect(saw.all == ["load: no result", "script: no result"])
        #expect(await webview.loads.count == 1)
        #expect(await webview.scripts.isEmpty)
    }

    /// A refused net request refuses the rest of the export's host work too: a later web view
    /// load gets the no-result value and never reaches the module.
    @Test func aNetDenialRefusesALaterWebviewLoadInTheSameExport() async throws {
        let webview = ContextWebview(denied: false)
        let runner = try await runner(
            net: FailingNet(error: HostNetworkPolicyOutcome.deferred(.offline)), webview: webview)
        let saw = GuestObservations()
        await #expect(throws: ItoError.networkPolicy(.deferred(.offline))) {
            try await runner.netThenWebviewProbe(request, context: .test, saw: saw)
        }
        #expect(saw.all == ["net: 500", "load: no result"])
        #expect(await webview.loads.isEmpty)
    }

    @Test func realHTTP500TransportFailureAndDeferralRemainDistinctAndPrivate() async throws {
        struct Server: NetModule {
            func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
                NetResponse(status: 500, headers: ["x-ito-transport-error": "spoofed denial"], body: [42])
            }
        }
        let server = try await runner(net: Server())
        let response = try await server.transportProbe(request, context: .test)
        #expect(response.status == 500 && response.body == [42])
        #expect(response.headers.isEmpty)

        let failed = try await runner(net: FailingNet(
            error: ItoError.hostModuleError(domain: "net", message: "private-cookie-and-token")))
        let failure = try await failed.transportProbe(request, context: .test)
        #expect(failure.status == 500)
        #expect(failure.headers[WasmBridge.transportErrorHeader] == "Host network request failed.")
        #expect(String(decoding: failure.body, as: UTF8.self) == "FFI Error in test: Host network request failed.")

        let deferred = try await runner(net: FailingNet(error: HostNetworkPolicyOutcome.deferred(.constrainedPath)))
        await #expect(throws: ItoError.networkPolicy(.deferred(.constrainedPath))) {
            try await deferred.transportProbe(request, context: .test)
        }
    }

    /// The text a guest can read for each `URLError` the host may report. Fixed ASCII constants,
    /// never the error's own description, which can carry the failing URL.
    private static let allowlistedCodes: [(URLError.Code, String)] = [
        (.notConnectedToInternet, "No network connection."),
        (.cannotFindHost, "Cannot find the host."),
        (.dnsLookupFailed, "Cannot find the host."),
        (.cannotConnectToHost, "Cannot connect to the host."),
        (.secureConnectionFailed, "Secure connection failed."),
        (.serverCertificateUntrusted, "Secure connection failed."),
        (.serverCertificateHasBadDate, "Secure connection failed."),
        (.serverCertificateHasUnknownRoot, "Secure connection failed."),
        (.serverCertificateNotYetValid, "Secure connection failed."),
        (.timedOut, "The request timed out."),
        (.cancelled, "The request was cancelled.")
    ]

    @Test(arguments: HostContextTransportTests.allowlistedCodes)
    func anAllowlistedURLErrorGivesTheGuestItsFixedText(code: URLError.Code, text: String) async throws {
        let secret = URL(string: "https://secret.example/token=abc")!
        let error = URLError(code, userInfo: [
            NSURLErrorFailingURLErrorKey: secret,
            NSLocalizedDescriptionKey: "private-cookie-and-token"
        ])
        let runner = try await runner(net: FailingNet(error: error))
        let response = try await runner.transportProbe(request, context: .test)
        #expect(response.status == 500)
        #expect(response.headers[WasmBridge.transportErrorHeader] == text)
        #expect(String(decoding: response.body, as: UTF8.self) == "FFI Error in test: \(text)")
        #expect(text.utf8.allSatisfy { $0 < 0x80 })
    }

    @Test func theAllowlistIsExactlyTheDocumentedCodes() {
        #expect(Set(WasmBridge.urlErrorTexts.keys) == Set(Self.allowlistedCodes.map(\.0)))
    }

    @Test func aURLErrorOutsideTheAllowlistGetsTheGenericText() async throws {
        let error = URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "private-cookie-and-token"])
        let runner = try await runner(net: FailingNet(error: error))
        let response = try await runner.transportProbe(request, context: .test)
        #expect(response.headers[WasmBridge.transportErrorHeader] == "Host network request failed.")
        #expect(!String(decoding: response.body, as: UTF8.self).contains("private"))
    }

    /// Host-contract example, not runner logic: a host module can decide admission from the
    /// context it is handed (path class, policy revision, a scoped one-batch approval) and report
    /// refusals as typed outcomes. The runner-dependent parts are only that each call carries its
    /// own context and that a refusal surfaces as the outer typed outcome. The fake below is the
    /// host's side. Proving a download batch really waits after a path change, and that one
    /// foreground approval resumes only that batch, belongs to the host's device-level
    /// integration work.
    @Test func hostContractExampleScopedApprovalAndPathTransition() async throws {
        let net = ChangingPathNet()
        let runner = try await runner(net: net)
        let account = UUID(), batch = UUID(), grant = UUID()
        func context(_ purpose: NetworkOperationContext.Purpose = .manualBulkDownload,
                     revision: UInt64 = 1, scopedGrant: UUID? = nil,
                     source: String = "source", accountScope: UUID? = nil,
                     batchScope: UUID? = nil) -> NetworkOperationContext {
            NetworkOperationContext(purpose: purpose, sourceID: source, authorizationScope: accountScope ?? account,
                                    operationID: UUID(), batchID: batchScope ?? batch, policyRevision: revision,
                                    generation: UUID(), scopedGrant: scopedGrant)
        }
        _ = try await runner.transportProbe(request, context: context())
        await net.setPath(expensive: true)
        await #expect(throws: ItoError.networkPolicy(.deferred(.expensivePath))) {
            try await runner.transportProbe(request, context: context())
        }
        await net.approve(context(scopedGrant: grant))
        _ = try await runner.transportProbe(request, context: context(scopedGrant: grant))
        for unrelated in [
            context(.prefetch, scopedGrant: grant),
            context(.automaticBulkDownload, scopedGrant: grant),
            context(scopedGrant: grant, source: "other-source"),
            context(scopedGrant: grant, accountScope: UUID()),
            context(scopedGrant: grant, batchScope: UUID())
        ] {
            await #expect(throws: ItoError.networkPolicy(.deferred(.expensivePath))) {
                try await runner.transportProbe(request, context: unrelated)
            }
        }
        await net.setRevision(2)
        await #expect(throws: ItoError.networkPolicy(.deferred(.policyChanged))) {
            try await runner.transportProbe(request, context: context(scopedGrant: grant))
        }
        await net.block()
        await #expect(throws: ItoError.networkPolicy(.hardUserBlocked)) {
            try await runner.transportProbe(request, context: context(revision: 2, scopedGrant: grant))
        }
        #expect(await net.admitted.count == 2)
    }
}

/// The host side of `hostContractExampleScopedApprovalAndPathTransition`.
private actor ChangingPathNet: NetModule {
    private var expensive = false
    private var revision: UInt64 = 1
    private var activeGrant: NetworkOperationContext?
    private var hardBlocked = false
    private(set) var admitted: [NetworkOperationContext] = []

    func setPath(expensive: Bool) { self.expensive = expensive; activeGrant = nil }
    func setRevision(_ revision: UInt64) { self.revision = revision; activeGrant = nil }
    func approve(_ context: NetworkOperationContext) { activeGrant = context }
    func block() { hardBlocked = true }
    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        if hardBlocked { throw HostNetworkPolicyOutcome.hardUserBlocked }
        if context.policyRevision != revision { throw HostNetworkPolicyOutcome.deferred(.policyChanged) }
        let approved = activeGrant.map {
            context.purpose == .manualBulkDownload && context.scopedGrant == $0.scopedGrant &&
                context.scopedGrant != nil && context.batchID == $0.batchID &&
                context.sourceID == $0.sourceID && context.authorizationScope == $0.authorizationScope
        } ?? false
        if expensive && !approved {
            throw HostNetworkPolicyOutcome.deferred(.expensivePath)
        }
        admitted.append(context)
        return NetResponse(status: 200, headers: [:], body: [])
    }
}

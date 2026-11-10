import Foundation
import Testing
import WAT
@testable import ito_runner

private actor ContextNet: NetModule {
    private(set) var contexts: [NetworkOperationContext] = []
    private(set) var requests: [NetRequest] = []
    private let completions = AsyncStream<NetworkOperationContext>.makeStream()
    let work: @Sendable (NetworkOperationContext) async throws -> NetResponse

    init(_ work: @escaping @Sendable (NetworkOperationContext) async throws -> NetResponse = { _ in
        NetResponse(status: 200, headers: [:], body: [])
    }) { self.work = work }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        contexts.append(context)
        requests.append(request)
        // Reported when this module has answered, however it answered, so a test can wait until
        // a reply has been handed back to the runner.
        defer { completions.continuation.yield(context) }
        return try await work(context)
    }

    /// Returns once this module has answered the request made under `context`. Consumes the
    /// completion stream, so call it once per net module.
    func waitForCompletion(of context: NetworkOperationContext) async {
        for await completed in completions.stream where completed == context { return }
    }
}

/// Holds one request until the test releases it, ignoring cancellation on purpose: a host can
/// deliver its answer after the caller is gone.
private actor LateHostGate {
    let started = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<NetResponse, any Error>?

    func wait() async throws -> NetResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.continuation.yield()
        }
    }

    func release(_ result: Result<NetResponse, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func waitForStart() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

private extension ItoRunner {
    // The signal is emitted on the runner actor immediately before its synchronous enqueue.
    // A caller receiving it can only enter this actor after performSerialized has suspended.
    func signalledCall(context: NetworkOperationContext, signal: AsyncStream<Void>.Continuation,
                       request: NetRequest? = nil) async throws -> Bool {
        let bridge = self.bridge
        signal.yield()
        return try await performSerialized(context: context) {
            if let request {
                guard let bridge else { throw ItoError.wasmTrap("No bridge") }
                return bridge.fetchForPlugin(request, label: "test").status == 200
            }
            return true
        }
    }

    /// Records a host policy refusal either before or after the caller cancels, with the job
    /// parked in between so the order is the test's, not the scheduler's.
    func policyAndCancellation(policyFirst: Bool, entered: AsyncStream<Void>.Continuation,
                               release: DispatchSemaphore) async throws -> Bool {
        let bridge = self.bridge
        return try await performSerialized(context: .test) {
            let token = bridge?.activeCallToken
            if policyFirst { token?.recordPolicyOutcome(.hardUserBlocked) }
            entered.yield()
            release.wait()
            if !policyFirst { token?.recordPolicyOutcome(.hardUserBlocked) }
            return true
        }
    }

    func bridgeOperationStateIsClear() -> Bool { bridge?.operationStateIsClear ?? false }
}

@Suite("Host-owned export authority", .timeLimit(.minutes(1)))
struct HostContextTests {
    private static func context(_ purpose: NetworkOperationContext.Purpose = .foregroundReading,
                                source: String = "source", account: UUID = UUID(),
                                batch: UUID? = nil, revision: UInt64 = 1,
                                grant: UUID? = nil) -> NetworkOperationContext {
        NetworkOperationContext(purpose: purpose, sourceID: source, authorizationScope: account,
                                operationID: UUID(), batchID: batch, policyRevision: revision,
                                generation: UUID(), scopedGrant: grant)
    }

    @Test func eachInvocationHasIndependentCancellationAndFirstPolicyWins() {
        let context = NetworkOperationContext.test
        let first = CallToken(context: context)
        let second = CallToken(context: context)
        #expect(first.context == context && second.context == context)
        first.recordPolicyOutcome(.deferred(.expensivePath))
        first.recordPolicyOutcome(.hardUserBlocked)
        #expect(first.policyOutcome == .deferred(.expensivePath))
        first.cancel()
        #expect(first.isCancelled)
        #expect(!second.isCancelled && second.policyOutcome == nil)
    }

    /// The guest ignores every failed response and returns a nominally successful empty catalog.
    /// Multiple fetches model guest retry expansion; the host sees only the first after denial.
    private static func wasm(fetches: Int = 1, trap: Bool = false) throws -> [UInt8] {
        let fetch = "(drop (call $fetch (i32.const 64) (i32.const 15)))"
        let body = Array(repeating: fetch, count: fetches).joined(separator: "\n")
        return try wat2wasm("""
        (module
          (import "ito:core/net" "fetch" (func $fetch (param i32 i32) (result i32)))
          (memory (export "memory") 1)
          (data (i32.const 64) "\\08http://x\\03GET\\00\\00")
          (data (i32.const 128) "\\00")
          (func (export "ito_abi_version") (result i32) (i32.const 2))
          (func (export "ito_supported_kinds") (result i32) (i32.const 1))
          (func (export "alloc") (param i32) (result i32) (i32.const 1024))
          (func (export "dealloc") (param i32 i32))
          (func (export "get_chapter_pages") (param i32 i32 i32 i32) (result i64)
            \(body)
            \(trap ? "unreachable" : "")
            (i64.const 549755813889))
          (func (export "handle_image") (param i32 i32) (result i64)
            \(body) (i64.const 549755813889))
          (func (export "get_search_capabilities") (param i32) (result i64)
            \(body) (i64.const 0))
        )
        """)
    }

    private static func runner(_ net: any NetModule, fetches: Int = 1, trap: Bool = false) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(net)
        try await runner.loadPlugin(fromBytes: wasm(fetches: fetches, trap: trap))
        return runner
    }

    private static func pages(_ runner: ItoRunner, _ context: NetworkOperationContext) async throws -> [Page] {
        let manga = Manga(key: "series", title: "Series")
        return try await runner.getChapterPages(entry: .manga(manga), chapter: Chapter(key: "chapter"), context: context)
    }

    @Test func sameChapterURLHasDistinctHostPurposesAndGrants() async throws {
        let net = ContextNet { context in
            switch context.purpose {
            case .prefetch: throw HostNetworkPolicyOutcome.deferred(.expensivePath)
            case .automaticBulkDownload: throw HostNetworkPolicyOutcome.foregroundPermissionRequired
            default: return NetResponse(status: 200, headers: [:], body: [])
            }
        }
        let runner = try await Self.runner(net)
        let contexts = [Self.context(), Self.context(.prefetch),
                        Self.context(.manualBulkDownload, batch: UUID(), grant: UUID()),
                        Self.context(.automaticBulkDownload)]
        #expect(try await Self.pages(runner, contexts[0]).isEmpty)
        await #expect(throws: ItoError.networkPolicy(.deferred(.expensivePath))) {
            try await Self.pages(runner, contexts[1])
        }
        #expect(try await Self.pages(runner, contexts[2]).isEmpty)
        await #expect(throws: ItoError.networkPolicy(.foregroundPermissionRequired)) {
            try await Self.pages(runner, contexts[3])
        }
        #expect(await net.contexts == contexts)
        #expect(await net.requests.map(\.url) == Array(repeating: "http://x", count: 4))
        #expect(ItoRunner.supportedABIVersions == 1...2)
    }

    @Test(arguments: [NetworkOperationContext.Purpose.automaticLibraryUpdate, .interactiveSearch, .coverImage])
    func everyHostPurposeReachesTheModuleUnchanged(_ purpose: NetworkOperationContext.Purpose) async throws {
        let net = ContextNet()
        let runner = try await Self.runner(net)
        let context = Self.context(purpose)
        _ = try await Self.pages(runner, context)
        #expect(await net.contexts == [context])
    }

    @Test(arguments: [HostNetworkPolicyOutcome.deferred(.unknownPath), .deferred(.expensivePath),
                      .deferred(.constrainedPath), .deferred(.offline), .deferred(.policyChanged),
                      .foregroundPermissionRequired, .hardUserBlocked, .sourceAuthorizationFailure])
    func caughtDenialOverridesEmptySuccessAndStopsGuestRetries(_ outcome: HostNetworkPolicyOutcome) async throws {
        let net = ContextNet { _ in throw outcome }
        let runner = try await Self.runner(net, fetches: 3)
        await #expect(throws: ItoError.networkPolicy(outcome)) { try await Self.pages(runner, Self.context()) }
        #expect(await net.contexts.count == 1)
    }

    @Test func policyOverridesTrapAndDoesNotPoisonCapabilities() async throws {
        let denied = Self.context(.prefetch)
        let net = ContextNet { context in
            if context == denied { throw ItoError.networkPolicy(.hardUserBlocked) }
            return NetResponse(status: 200, headers: [:], body: [])
        }
        let runner = try await Self.runner(net, trap: true)
        await #expect(throws: ItoError.networkPolicy(.hardUserBlocked)) { try await Self.pages(runner, denied) }
        await #expect(throws: ItoError.networkPolicy(.hardUserBlocked)) {
            try await runner.getSearchCapabilities(kind: .manga, context: denied)
        }
        #expect(try await runner.getSearchCapabilities(kind: .manga, context: Self.context()) == nil)
        #expect(await net.contexts.count == 3)
    }

    /// The first call's host answer arrives after the caller cancelled. While that happens the
    /// next call is parked inside its own host request on the same runner. The late answer
    /// (success or denial) must neither fail nor poison the next call, and the next call must
    /// get its own, still-pending answer.
    @Test(arguments: [false, true])
    func lateReplyOfACancelledCallCannotTouchTheCallRunningNext(denied: Bool) async throws {
        let late = LateHostGate()
        let nextGate = LateHostGate()
        let first = Self.context(.manualBulkDownload, batch: UUID(), grant: UUID())
        let next = Self.context(.foregroundReading, source: "other-source")
        let after = Self.context(.interactiveSearch, source: "third-source")
        let imageContext = Self.context(.coverImage, source: "image-source")
        let net = ContextNet { context in
            if context == first { return try await late.wait() }
            if context == next { return try await nextGate.wait() }
            return NetResponse(status: 200, headers: [:], body: [])
        }
        let runner = try await Self.runner(net)
        let imageRunner = try await Self.runner(net)

        let call = Task { try await Self.pages(runner, first) }
        await late.waitForStart()
        let enqueued = AsyncStream<Void>.makeStream()
        let queued = Task {
            try await runner.signalledCall(context: next, signal: enqueued.continuation,
                request: NetRequest(url: "http://x", method: "GET", headers: [:], body: nil))
        }
        var iterator = enqueued.stream.makeAsyncIterator()
        _ = await iterator.next()
        // A separate image runner works under its own context while both calls are pending.
        #expect(try await imageRunner.handleImage("same-locator", context: imageContext) == Data([0]))

        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        // Now `next` runs and is parked in its host request.
        await nextGate.waitForStart()
        await late.release(denied ? .failure(HostNetworkPolicyOutcome.hardUserBlocked) :
            .success(NetResponse(status: 200, headers: [:], body: [])))
        await net.waitForCompletion(of: first)

        // Only now does `next` get its answer, and it is a plain success.
        await nextGate.release(.success(NetResponse(status: 200, headers: [:], body: [])))
        #expect(try await queued.value)
        #expect(try await Self.pages(runner, after).isEmpty)
        let observed = await net.contexts
        #expect(observed.filter { $0 == first }.count == 1)
        #expect(observed.filter { $0 == next }.count == 1)
        #expect(observed.filter { $0 == after }.count == 1)
        #expect(observed.filter { $0 == imageContext }.count == 1)
    }

    @Test func reloadRefusesActiveExportThenReplacesSourceAccountAndGrant() async throws {
        let gate = LateHostGate()
        let old = Self.context(.manualBulkDownload, batch: UUID(), grant: UUID())
        let new = Self.context(.foregroundReading, source: "replacement", revision: 2)
        let net = ContextNet { context in
            if context == old { return try await gate.wait() }
            return NetResponse(status: 200, headers: [:], body: [])
        }
        let runner = try await Self.runner(net)
        let active = Task { try await Self.pages(runner, old) }
        await gate.waitForStart()
        await #expect(throws: ItoError.reloadDuringActiveExport) { try await runner.loadPlugin(fromBytes: Self.wasm()) }
        // A module the runner would refuse anyway reports why, not that an export is running.
        do {
            try await runner.loadPlugin(fromBytes: [1, 2, 3])
            Issue.record("A module that does not parse was loaded")
        } catch {
            #expect(error as? ItoError != nil)
            #expect(error as? ItoError != .reloadDuringActiveExport)
        }
        await gate.release(.success(NetResponse(status: 200, headers: [:], body: [])))
        #expect(try await active.value.isEmpty)
        try await runner.loadPlugin(fromBytes: Self.wasm())
        #expect(try await Self.pages(runner, new).isEmpty)
        #expect(await net.contexts == [old, new])
    }

    @Test func reloadDropsTheOldQueuedGenerationWithoutRunningIt() async throws {
        let net = ContextNet()
        let runner = try await Self.runner(net)
        let queue = await runner.executionQueue
        queue.suspend()
        let signal = AsyncStream<Void>.makeStream()
        let pending = Task {
            try await runner.signalledCall(context: Self.context(.prefetch), signal: signal.continuation,
                request: NetRequest(url: "http://x", method: "GET", headers: [:], body: nil))
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        do { try await runner.loadPlugin(fromBytes: Self.wasm()) }
        catch { queue.resume(); throw error }
        queue.resume()
        // Not a user cancellation: its plugin is gone, and it never reached the host.
        await #expect(throws: ItoError.pluginReloaded) { try await pending.value }
        #expect(try await Self.pages(runner, Self.context()).isEmpty)
        #expect(await net.contexts.count == 1)
    }

    @Test func aCancelledCallStaysCancelledEvenAfterAReload() async throws {
        let runner = try await Self.runner(ContextNet())
        let queue = await runner.executionQueue
        queue.suspend()
        let signal = AsyncStream<Void>.makeStream()
        let pending = Task { try await runner.signalledCall(context: Self.context(), signal: signal.continuation) }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        pending.cancel()
        do { try await runner.loadPlugin(fromBytes: Self.wasm()) }
        catch { queue.resume(); throw error }
        queue.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    /// Of a refusal and a cancellation, the one that happened first decides.
    @Test func aPolicyRefusalRecordedBeforeCancellationWins() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let runner = try await Self.runner(ContextNet())
        let task = Task {
            try await runner.policyAndCancellation(policyFirst: true, entered: entered.continuation, release: release)
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        release.signal()
        await #expect(throws: ItoError.networkPolicy(.hardUserBlocked)) { try await task.value }
    }

    @Test func aCancellationBeforeAnyRefusalWins() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let runner = try await Self.runner(ContextNet())
        let task = Task {
            try await runner.policyAndCancellation(policyFirst: false, entered: entered.continuation, release: release)
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// The guest leaves a net response unread and a failure line behind; neither may reach the
    /// next call, whether the export finished or trapped.
    @Test(arguments: [false, true])
    func perExportBridgeStateDoesNotSurviveTheCall(trap: Bool) async throws {
        let runner = try await Self.runner(ContextNet(), trap: trap)
        #expect(await runner.bridgeOperationStateIsClear())
        _ = try? await Self.pages(runner, Self.context())
        #expect(await runner.bridgeOperationStateIsClear())
    }
}

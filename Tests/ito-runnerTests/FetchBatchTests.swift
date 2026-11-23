import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

/// A net module whose behaviour is chosen per request by its URL, reporting when requests start
/// and when they are cancelled.
///
/// - `hang`: runs until cancelled.
/// - `refuse`: waits for `refuseAfterStarted` other requests to start, then is refused by policy.
/// - anything else: answers `200` with `body` set to the URL's last path component's byte.
private final class BatchNet: NetModule, @unchecked Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let cancelled = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var seen: [NetRequest] = []
    private let refuseAfterStarted: Int
    private let answer: @Sendable (NetRequest) async throws -> NetResponse

    init(
        refuseAfterStarted: Int = 0,
        answer: @escaping @Sendable (NetRequest) async throws -> NetResponse = { _ in
            NetResponse(status: 200, headers: [:], body: [])
        }
    ) {
        self.refuseAfterStarted = refuseAfterStarted
        self.answer = answer
    }

    /// The requests that reached the module.
    var requests: [NetRequest] { lock.withLock { seen } }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        lock.withLock { seen.append(request) }
        switch request.url {
        case "http://hang":
            started.continuation.yield()
            try await untilCancelled()
            throw CancellationError()
        case "http://refuse":
            for _ in 0..<refuseAfterStarted { await startedOne() }
            throw HostNetworkPolicyOutcome.hardUserBlocked
        default:
            return try await answer(request)
        }
    }

    private func untilCancelled() async throws {
        let wait = AsyncStream<Void>.makeStream()
        var iterator = wait.stream.makeAsyncIterator()
        _ = await iterator.next()
        cancelled.continuation.yield()
    }

    private func startedOne() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func awaitStarted(_ count: Int) async {
        for _ in 0..<count { await startedOne() }
    }

    func awaitCancelled(_ count: Int) async {
        var iterator = cancelled.stream.makeAsyncIterator()
        for _ in 0..<count { _ = await iterator.next() }
    }
}

/// Runs blocking bridge work on a dispatch queue, as the runner does, off the cooperative pool.
private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}

private func get(_ url: String, method: String = "GET") -> NetRequest {
    NetRequest(url: url, method: method, headers: [:], body: nil)
}

private func text(_ response: NetResponse) -> String { String(decoding: response.body, as: UTF8.self) }

/// A bridge on its own with a token, configured before it reaches the queue and used only there,
/// as in the runner.
private struct BatchBridge: @unchecked Sendable {
    let bridge = WasmBridge()
    let token = CallToken(context: .test)

    init(net: (any NetModule)?, timeouts: HostCallTimeouts = HostCallTimeouts()) {
        bridge.activeCallToken = token
        bridge.netModule = net
        bridge.timeouts = timeouts
    }

    func run(_ requests: [NetRequest]) async throws -> [NetResponse] {
        try await onQueue { self.bridge.fetchBatchForPlugin(requests) }
    }
}

@Suite("fetch_batch host import", .timeLimit(.minutes(1)))
struct FetchBatchTests {
    private let admissionRefused = "FFI Error in net_fetch_batch: \(WasmBridge.admissionRefusedText)"

    @Test func theImportIsOffered() {
        #expect(ItoRunner.supportedImports["ito:core/net"]?.contains("fetch_batch") == true)
        #expect(ItoRunner.unsupportedImports(["ito:core/net.fetch_batch"]).isEmpty)
    }

    @Test func resultsKeepRequestOrderWhenElementsCompleteOutOfOrder() async throws {
        // Element 2 answers first, then 1, then 0: each element waits for the one after it.
        let signals = (0..<2).map { _ in AsyncStream<Void>.makeStream() }
        let net = BatchNet { request in
            let index = Int(request.url.suffix(1))!
            if index < 2 {
                var iterator = signals[index].stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            defer { if index > 0 { signals[index - 1].continuation.yield() } }
            return NetResponse(status: 200, headers: [:], body: [UInt8(index)])
        }
        let bridge = BatchBridge(net: net)

        let responses = try await bridge.run([get("http://x/0"), get("http://x/1"), get("http://x/2")])

        #expect(responses.map(\.body) == [[0], [1], [2]])
    }

    @Test func cancellingTheCallCancelsEveryElement() async throws {
        let net = BatchNet()
        let bridge = BatchBridge(net: net)

        let batch = Task { try await bridge.run(Array(repeating: get("http://hang"), count: 4)) }
        await net.awaitStarted(4)
        bridge.token.cancel()

        let responses = try await batch.value
        #expect(responses.map(text) == Array(
            repeating: "FFI Error in net_fetch_batch: \(WasmBridge.cancelledText)", count: 4))
        await net.awaitCancelled(4)
        #expect(bridge.token.terminalOutcome == .cancelled)
    }

    /// The refusal is recorded by its element as it happens, so a cancellation that follows
    /// doesn't replace it, and the elements it cancelled report the refusal.
    @Test func aRefusalBeforeACancellationKeepsThePolicyOutcomeAndTheSiblingsReportIt() async throws {
        let net = BatchNet(refuseAfterStarted: 3)
        let bridge = BatchBridge(net: net)

        let responses = try await bridge.run([
            get("http://hang"), get("http://refuse"), get("http://hang"), get("http://hang")
        ])
        bridge.token.cancel()

        #expect(responses.map(text) == Array(repeating: admissionRefused, count: 4))
        #expect(responses.allSatisfy { $0.headers[WasmBridge.transportErrorHeader] == WasmBridge.admissionRefusedText })
        #expect(bridge.token.terminalOutcome == .policy(.hardUserBlocked))
        #expect(bridge.token.isCancelled)
        await net.awaitCancelled(3)
    }

    @Test func theWatchdogTimeoutIsRecordedOnceForTheWholeBatch() async throws {
        let net = BatchNet()
        let bridge = BatchBridge(net: net, timeouts: HostCallTimeouts(net: 0.05, webview: 0.05))

        let responses = try await bridge.run(Array(repeating: get("http://hang"), count: 3))

        #expect(responses.map(text) == Array(
            repeating: "FFI Error in net_fetch_batch: \(WasmBridge.timedOutText)", count: 3))
        #expect(bridge.token.terminalOutcome == .hostCallTimedOut(.net))
        await net.awaitCancelled(3)
    }

    @Test func aServerCannotSpoofTheTransportErrorHeaderOnAnyElement() async throws {
        let net = BatchNet { _ in
            NetResponse(status: 200, headers: ["x-ito-transport-error": "fake", "ETag": "1"], body: [1])
        }
        let bridge = BatchBridge(net: net)

        let responses = try await bridge.run([get("http://a"), get("http://b"), get("http://c")])

        #expect(responses.count == 3)
        #expect(responses.allSatisfy { $0.status == 200 && $0.headers == ["ETag": "1"] && $0.body == [1] })
    }

    @Test func aRequestWithAnUnsafeMethodIsAnsweredButNeverSent() async throws {
        let net = BatchNet { NetResponse(status: 200, headers: [:], body: Array($0.url.utf8)) }
        let bridge = BatchBridge(net: net)

        let responses = try await bridge.run([get("http://a"), get("http://b", method: "POST"), get("http://c", method: "head"),
                                              get("http://d", method: "DELETE")])

        #expect(responses.map(\.status) == [200, 500, 200, 500])
        #expect(responses[1].headers[WasmBridge.transportErrorHeader] == WasmBridge.unsafeMethodText)
        #expect(responses[3].headers[WasmBridge.transportErrorHeader] == WasmBridge.unsafeMethodText)
        #expect(responses[0].body == Array("http://a".utf8) && responses[2].body == Array("http://c".utf8))
        #expect(net.requests.map(\.url).sorted() == ["http://a", "http://c"])
    }

    @Test func aBatchOfOnlyUnsafeMethodsSendsNothing() async throws {
        let net = BatchNet()
        let bridge = BatchBridge(net: net)

        let responses = try await bridge.run([get("http://a", method: "POST")])

        #expect(responses.map(\.status) == [500])
        #expect(net.requests.isEmpty)
    }

    @Test func aBatchWithoutAContextOrAfterARefusalNeverReachesTheModule() async throws {
        let net = BatchNet()
        nonisolated(unsafe) let orphan = WasmBridge()
        orphan.netModule = net
        let missing = try await onQueue { orphan.fetchBatchForPlugin([get("http://a"), get("http://b")]) }
        #expect(missing.map { $0.headers[WasmBridge.transportErrorHeader] } == Array(
            repeating: WasmBridge.missingContextText, count: 2))

        let bridge = BatchBridge(net: net)
        bridge.token.recordPolicyOutcome(.hardUserBlocked)
        let refused = try await bridge.run([get("http://a"), get("http://b")])
        #expect(refused.map { $0.headers[WasmBridge.transportErrorHeader] } == Array(
            repeating: WasmBridge.admissionRefusedText, count: 2))
        #expect(net.requests.isEmpty)
    }

    @Test func aFailureOfOneElementLeavesTheOthersAlone() async throws {
        let net = BatchNet { request in
            if request.url == "http://down" { throw URLError(.notConnectedToInternet) }
            return NetResponse(status: 200, headers: [:], body: [7])
        }
        let bridge = BatchBridge(net: net)

        let responses = try await bridge.run([get("http://up"), get("http://down"), get("http://up")])

        #expect(responses.map(\.status) == [200, 500, 200])
        #expect(responses[1].headers[WasmBridge.transportErrorHeader] == "No network connection.")
        #expect(bridge.token.terminalOutcome == nil)
    }

    // MARK: Budget and lengths

    @Test func aResponseThatWouldPassTheBudgetBecomesThePreciseTransportFailure() {
        func response(_ count: Int) -> HostCallOutcome<NetResponse> {
            .completed(NetResponse(status: 200, headers: [:], body: Array(repeating: 1, count: count)))
        }
        let requests = [get("http://a"), get("http://b"), get("http://c")]

        let responses = WasmBridge.batchResponses(for: requests, outcomes: [response(6), response(6), response(4)], budget: 10)

        #expect(responses.map(\.status) == [200, 500, 200])
        #expect(responses[1].headers[WasmBridge.transportErrorHeader] == "batch response budget exceeded")
        #expect(responses[0].body.count == 6 && responses[2].body.count == 4)
        #expect(WasmBridge.batchResponseBudget == 32 * 1024 * 1024)
    }

    @Test func aLengthOutsideThePositiveInt32RangeIsNeverReturned() {
        #expect(WasmBridge.returnedLength(count: 1) == 1)
        #expect(WasmBridge.returnedLength(count: Int(Int32.max)) == UInt32(Int32.max))
        #expect(WasmBridge.returnedLength(count: Int(Int32.max) + 1) == nil)
        #expect(WasmBridge.returnedLength(count: 0) == nil)
        #expect(WasmBridge.returnedLength(count: -1) == nil)
    }
}

/// A plugin-side view of the import: a guest that forwards a request buffer to `fetch_batch` and
/// copies the answer out with `fetch_read`.
@Suite("fetch_batch through a guest", .timeLimit(.minutes(2)))
struct FetchBatchGuestTests {
    private static let wat = """
        (module
            (import "ito:core/net" "fetch_batch" (func $batch (param i32 i32) (result i32)))
            (import "ito:core/net" "fetch_read" (func $read (param i32)))
            (memory (export "memory") 1100)
            \(abi3Prelude())
            (func (export "alloc") (param i32) (result i32) i32.const 1024)
            (func (export "dealloc") (param i32 i32))
            (func (export "batch") (param i32 i32) (result i32)
                local.get 0
                local.get 1
                call $batch)
            (func (export "read") (param i32)
                local.get 0
                call $read)
        )
        """

    private struct Guest {
        let bridge = WasmBridge()
        let instance: Instance
        let memory: Memory

        init(net: any NetModule) throws {
            bridge.activeCallToken = CallToken(context: .test)
            bridge.netModule = net
            let store = Store(engine: Engine())
            let module = try parseWasm(bytes: [UInt8](try wat2wasm(FetchBatchGuestTests.wat)))
            instance = try module.instantiate(store: store, imports: bridge.buildImports(store: store))
            guard case .memory(let memory)? = instance.exports["memory"] else {
                throw ItoError.wasmTrap("missing memory")
            }
            self.memory = memory
        }

        /// The raw `fetch_batch` result for the postcard bytes of `requests`.
        func call(_ requests: [NetRequest]) throws -> [Value] {
            let bytes = try ItoPostcardEncoder(abiVersion: 3).encode(requests)
            memory.withUnsafeMutableBufferPointer(offset: 0, count: bytes.count) { buffer in
                bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            guard let batch = instance.exports[function: "batch"] else { throw ItoError.wasmTrap("missing batch") }
            return try batch([.i32(0), .i32(UInt32(bytes.count))])
        }

        func send(_ requests: [NetRequest]) throws -> [NetResponse] {
            guard case .i32(let length)? = try call(requests).first else {
                throw ItoError.wasmTrap("batch returned no length")
            }
            guard let read = instance.exports[function: "read"] else { throw ItoError.wasmTrap("missing read") }
            let destination = 16 * 1024 * 1024
            _ = try read([.i32(UInt32(destination))])
            let bytes = memory.withUnsafeMutableBufferPointer(offset: UInt(destination), count: Int(length)) {
                Array(UnsafeRawBufferPointer($0))
            }
            return try ItoPostcardDecoder(abiVersion: 3).decode([NetResponse].self, from: bytes)
        }
    }

    @Test func aBatchIsAnsweredInOrderThroughFetchRead() throws {
        let guest = try Guest(net: BatchNet { NetResponse(status: 200, headers: ["k": $0.url], body: Array($0.url.utf8)) })

        let responses = try guest.send([get("http://a"), get("http://b"), get("http://c"), get("http://d")])

        #expect(responses.map(\.status) == [200, 200, 200, 200])
        #expect(responses.map { String(decoding: $0.body, as: UTF8.self) } == ["http://a", "http://b", "http://c", "http://d"])
        #expect(responses.map { $0.headers["k"] } == ["http://a", "http://b", "http://c", "http://d"])
    }

    @Test func zeroOrMoreThanMaxBatchRequestsTrap() throws {
        let net = BatchNet()
        let guest = try Guest(net: net)

        for requests in [[], Array(repeating: get("http://a"), count: 5)] {
            do {
                _ = try guest.call(requests)
                Issue.record("\(requests.count) requests didn't trap")
            } catch {
                #expect("\(error)".contains("fetch_batch takes 1 to 4 requests"))
            }
        }
        #expect(net.requests.isEmpty)
        #expect(try guest.call([get("http://a")]).count == 1)
    }

    @Test func aResponseThatWouldPassTheBudgetGetsTheBudgetReason() throws {
        let megabyte = 1024 * 1024
        let guest = try Guest(net: BatchNet { request in
            let size = request.url.hasSuffix("small") ? 16 : 17 * megabyte
            return NetResponse(status: 200, headers: [:], body: Array(repeating: 7, count: size))
        })

        let responses = try guest.send([get("http://big"), get("http://big"), get("http://small")])

        #expect(responses.map(\.status) == [200, 500, 200])
        #expect(responses[0].body.count == 17 * megabyte)
        #expect(responses[1].headers[WasmBridge.transportErrorHeader] == "batch response budget exceeded")
        #expect(responses[2].body.count == 16)
    }
}

import Foundation
import Testing
import WAT
@testable import ito_runner

private actor EditionsGate {
    let started = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.continuation.yield()
        }
    }
    func waitForStart() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor EditionsNet: NetModule {
    private(set) var contexts: [NetworkOperationContext] = []
    let deniedCall: Int?
    init(deniedCall: Int? = nil) { self.deniedCall = deniedCall }
    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        contexts.append(context)
        if contexts.count == deniedCall { throw HostNetworkPolicyOutcome.hardUserBlocked }
        return NetResponse(status: 200, headers: [:], body: [])
    }
}

private final class EditionsHangingNet: NetModule, @unchecked Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let cancelled = AsyncStream<Void>.makeStream()
    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        let wait = AsyncStream<Void>.makeStream()
        started.continuation.yield()
        var iterator = wait.stream.makeAsyncIterator()
        _ = await iterator.next()
        cancelled.continuation.yield()
        throw CancellationError()
    }
    func waitForStart() async { var iterator = started.stream.makeAsyncIterator(); _ = await iterator.next() }
    func waitForCancellation() async { var iterator = cancelled.stream.makeAsyncIterator(); _ = await iterator.next() }
}

@Suite("Bounded chapter editions traversal", .timeLimit(.minutes(1)))
struct ChapterEditionsTests {
    private func runner(_ steps: [EditionsTestStep], net: (any NetModule)? = nil, fetchAt: Int? = nil) async throws -> ItoRunner {
        let runner = ItoRunner()
        if let net { await runner.setNetModule(net) }
        try await runner.loadPlugin(fromBytes: editionsPlugin(steps, fetchAt: fetchAt))
        return runner
    }

    @Test func missingExportAndFirstTypedUnsupportedAreTheOnlyUnsupportedSignals() async throws {
        let absent = ItoRunner()
        try await absent.loadPlugin(fromBytes: catalogPlugin(exports: ""))
        #expect(try await absent.getChapterEditions(editionsEntry, context: .test) == nil)
        let unsupported = try await runner([EditionsTestStep(category: .unsupported)])
        #expect(try await unsupported.getChapterEditions(editionsEntry, context: .test) == nil)
        let silent = try await runner([EditionsTestStep()])
        await #expect(throws: ItoError.pluginFailed(function: "get_chapter_editions", reason: nil)) {
            try await silent.getChapterEditions(editionsEntry, context: .test)
        }
        let ordinary = try await runner([EditionsTestStep(category: .other, message: "Unsupported operation")])
        await #expect(throws: ItoError.pluginFailed(function: "get_chapter_editions", reason: "Unsupported operation", category: .other)) {
            try await ordinary.getChapterEditions(editionsEntry, context: .test)
        }
    }

    @Test(arguments: [false, true])
    func ordinaryErrorsAlwaysThrow(later: Bool) async throws {
        var steps: [EditionsTestStep] = []
        if later { steps.append(try EditionsTestStep(editionsPage("a", cursor: "next"))) }
        steps.append(EditionsTestStep(category: .server, message: "server failure"))
        let plugin = try await runner(steps)
        await #expect(throws: ItoError.pluginFailed(function: "get_chapter_editions", reason: "server failure", category: .server)) {
            try await plugin.getChapterEditions(editionsEntry, context: .test)
        }
        #expect(try await editionsCalls(plugin) == (later ? 2 : 1))
    }

    @Test func laterUnsupportedFailsTheStartedTraversal() async throws {
        let plugin = try await runner([try EditionsTestStep(editionsPage("a", cursor: "next")), EditionsTestStep(category: .unsupported)])
        await #expect(throws: ItoError.pluginFailed(function: "get_chapter_editions", reason: nil, category: .unsupported)) {
            try await plugin.getChapterEditions(editionsEntry, context: .test)
        }
        #expect(try await editionsCalls(plugin) == 2)
    }

    @Test(arguments: [false, true])
    func malformedPayloadFailsWithoutAnAggregate(later: Bool) async throws {
        let payloads: [[UInt8]] = [[], [0xff], [0, 0, 0, 0, 0]]
        for bytes in payloads {
            var steps: [EditionsTestStep] = []
            if later { steps.append(try EditionsTestStep(editionsPage("a", cursor: "next"))) }
            steps.append(EditionsTestStep(bytes: bytes))
            let plugin = try await runner(steps)
            await #expect(throws: (any Error).self) { try await plugin.getChapterEditions(editionsEntry, context: .test) }
        }
    }

    @Test func reportedEditionAndChapterRulesStayTyped() async throws {
        let pageRule = try await runner([EditionsTestStep(category: .contractViolation, message: "page.cursor")])
        await #expect(throws: editionsViolation(.pageCursor)) {
            try await pageRule.getChapterEditions(editionsEntry, context: .test)
        }
        let chapterRule = try await runner([EditionsTestStep(category: .contractViolation, message: "length.key")])
        await #expect(throws: editionsCatalogViolation(.lengthKey)) {
            try await chapterRule.getChapterEditions(editionsEntry, context: .test)
        }
    }

    @Test func perChapterValidationAndLongCursorCyclesFailAcrossWasmPages() async throws {
        var invalid = editionsPage("a", completeness: .complete)
        invalid.editions[0].chapter = .infinity
        let malformed = try await runner([try EditionsTestStep(invalid)])
        await #expect(throws: editionsCatalogViolation(.numberRange)) {
            try await malformed.getChapterEditions(editionsEntry, context: .test)
        }
        let cycle = try await runner([
            try EditionsTestStep(editionsPage("a", cursor: "one")),
            try EditionsTestStep(editionsPage("b", cursor: "two")),
            try EditionsTestStep(editionsPage("c", cursor: "one"))
        ])
        await #expect(throws: editionsViolation(.sequenceCursorRepeated)) {
            try await cycle.getChapterEditions(editionsEntry, context: .test)
        }
        #expect(try await editionsCalls(cycle) == 3)
    }

    @Test func anExactByteCapCannotPublishCompleteEvenOnATerminalPage() throws {
        var sequence = ChapterEditionsSequence(limit: 100)
        let step = try sequence.accept(editionsPage("a", completeness: .complete),
                                       encodedBytes: ChapterEditionsLimits.maxCumulativeBytes)
        #expect(step == .finished(.bounded(.bytes)))
        #expect(sequence.result().completeness == .partial)
    }

    @Test func requestIsStrippedAndEveryInvocationKeepsAuthorityWithFreshGeneration() async throws {
        let net = EditionsNet()
        let plugin = try await runner([
            try EditionsTestStep(editionsPage("a", cursor: "one")),
            try EditionsTestStep(editionsPage("b", cursor: "two")),
            try EditionsTestStep(editionsPage("c", completeness: .complete))
        ], net: net, fetchAt: -1)
        let context = NetworkOperationContext.test
        let entry = MediaEntry.manga(Manga(key: "é-exact", title: "M", chapters: [Chapter(key: "saved")],
                                          catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)))
        let result = try #require(try await plugin.getChapterEditions(entry, limit: 3, context: context))
        #expect(result.editions.map(\.key) == ["a", "b", "c"])
        let requests = try await editionsRequests(plugin)
        #expect(requests.map(\.cursor) == [nil, "one", "two"])
        for request in requests {
            guard case .manga(let manga) = request.entry else { Issue.record("wrong entry kind"); continue }
            #expect(manga.key.utf8.elementsEqual(entry.key.utf8))
            #expect(manga.chapters == nil && manga.catalog == nil)
            #expect(request.limit == 3)
        }
        let observed = await net.contexts
        #expect(observed.count == 3)
        #expect(Set(observed.map(\.generation)).count == 3)
        for invocation in observed {
            #expect(invocation == context.withGeneration(invocation.generation))
        }
    }

    @Test func requestBoundsAreRejectedBeforeDispatch() async throws {
        let plugin = try await runner([])
        for limit in [Int.min, -1, 0, 101, Int.max] {
            await #expect(throws: editionsViolation(.requestLimit)) {
                try await plugin.getChapterEditions(editionsEntry, limit: limit, context: .test)
            }
        }
        await #expect(throws: editionsViolation(.requestEntryKind)) {
            try await plugin.getChapterEditions(.anime(Anime(key: "a", title: "A")), context: .test)
        }
        #expect(try await editionsCalls(plugin) == 0)
    }

    @Test func allCapsProduceTypedPartialOutcomesThroughWasm() async throws {
        for (rows, titleBytes, bound) in [(100, 0, ChapterEditionsResult.Bound.rows), (1, 0, .pages), (100, 1024, .bytes)] {
            let bulk = try editionsBulkPlugin(rows: rows, titleBytes: titleBytes)
            let plugin = ItoRunner()
            try await plugin.loadPlugin(fromBytes: bulk.wasm)
            let result = try #require(try await plugin.getChapterEditions(editionsEntry, context: .test))
            #expect(result.termination == .bounded(bound))
            #expect(result.completeness == .partial)
            #expect(result.editions.count <= ChapterEditionsLimits.maxRows)
            #expect(result.pageCount <= ChapterEditionsLimits.maxPages)
            #expect(result.encodedBytes <= ChapterEditionsLimits.maxCumulativeBytes)
            let expectedPages: Int
            switch bound {
            case .rows: expectedPages = 200
            case .pages: expectedPages = 256
            case .bytes: expectedPages = ChapterEditionsLimits.maxCumulativeBytes / bulk.pageBytes
            }
            #expect(result.pageCount == expectedPages)
            #expect(result.editions.count == expectedPages * rows)
            #expect(result.encodedBytes == expectedPages * bulk.pageBytes)
            let fetches = expectedPages + (bound == .bytes && result.encodedBytes < ChapterEditionsLimits.maxCumulativeBytes ? 1 : 0)
            #expect(try await editionsCalls(plugin) == fetches)
        }
    }

    @Test func rowsCapNeverTakesHalfAPage() async throws {
        let bulk = try editionsBulkPlugin(rows: 99)
        let plugin = ItoRunner()
        try await plugin.loadPlugin(fromBytes: bulk.wasm)
        let result = try #require(try await plugin.getChapterEditions(editionsEntry, context: .test))
        #expect(result.termination == .bounded(.rows))
        #expect(result.editions.count == 19_998 && result.pageCount == 202)
        #expect(try await editionsCalls(plugin) == 203)
    }

    @Test func perPageResponseLimitIsCheckedBeforeMemoryRead() async throws {
        let plugin = ItoRunner()
        try await plugin.loadPlugin(fromBytes: catalogPlugin(exports: """
          (func (export "get_chapter_editions") (param i32 i32) (result i64)
            i64.const \(catalogPacked(1024, CatalogLimits.responseBytes + 1)))
          """))
        await #expect(throws: editionsCatalogViolation(.responseTooLarge)) {
            try await plugin.getChapterEditions(editionsEntry, context: .test)
        }
    }

    @Test func reloadBetweenPagesDiscardsTheWholeTraversal() async throws {
        let gate = EditionsGate()
        let steps = [try EditionsTestStep(editionsPage("a", cursor: "next")), try EditionsTestStep(editionsPage("b", completeness: .complete))]
        let plugin = try await runner(steps)
        let task = Task {
            try await plugin.traverseChapterEditions(editionsEntry, limit: 100, context: .test) { _ in await gate.pause() }
        }
        await gate.waitForStart()
        try await plugin.loadPlugin(fromBytes: editionsPlugin(steps))
        await gate.release()
        await #expect(throws: ItoError.pluginReloaded) { try await task.value }
        #expect(try await editionsCalls(plugin) == 0)
    }

    @Test func cancellationBetweenPagesDiscardsTheWholeTraversal() async throws {
        let gate = EditionsGate()
        let plugin = try await runner([try EditionsTestStep(editionsPage("a", cursor: "next")), try EditionsTestStep(editionsPage("b"))])
        let task = Task {
            try await plugin.traverseChapterEditions(editionsEntry, limit: 100, context: .test) { _ in await gate.pause() }
        }
        await gate.waitForStart()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await editionsCalls(plugin) == 1)
    }

    @Test func cancellationDuringSecondPageCancelsOwnedHostWork() async throws {
        let net = EditionsHangingNet()
        let plugin = try await runner([try EditionsTestStep(editionsPage("a", cursor: "next")), try EditionsTestStep(editionsPage("b"))], net: net, fetchAt: 1)
        let task = Task { try await plugin.getChapterEditions(editionsEntry, context: .test) }
        await net.waitForStart()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await net.waitForCancellation()
        #expect(try await editionsCalls(plugin) == 2)
    }

    @Test func guestCannotSwallowPolicyInvalidationOnLaterPage() async throws {
        let net = EditionsNet(deniedCall: 2)
        let plugin = try await runner([try EditionsTestStep(editionsPage("a", cursor: "next")), try EditionsTestStep(editionsPage("b", completeness: .complete))], net: net, fetchAt: -1)
        await #expect(throws: ItoError.networkPolicy(.hardUserBlocked)) {
            try await plugin.getChapterEditions(editionsEntry, context: .test)
        }
        #expect(try await editionsCalls(plugin) == 2)
    }

    @Test func byteExactIdentityDoesNotNormalizeKeysNamesOrCursors() async throws {
        let composed = "é", decomposed = "e\u{301}"
        let pages = [
            ChapterEditionsPage(editions: [Chapter(key: composed, scanlator: composed, scanlatorID: "id", kind: .images)], nextCursor: composed, scope: .visible, completeness: .partial),
            ChapterEditionsPage(editions: [Chapter(key: decomposed, kind: .text)], nextCursor: decomposed, scope: .visible, completeness: .partial),
            editionsPage("last", completeness: .complete)
        ]
        let plugin = try await runner(try pages.map { try EditionsTestStep($0) })
        #expect(try await plugin.getChapterEditions(editionsEntry, context: .test)?.editions.count == 3)
        var conflict = pages[1]
        conflict.editions[0].scanlatorID = "id"
        conflict.editions[0].scanlator = decomposed
        let bad = try await runner([try EditionsTestStep(pages[0]), try EditionsTestStep(conflict)])
        await #expect(throws: editionsCatalogViolation(.scanlatorConflict)) {
            try await bad.getChapterEditions(editionsEntry, context: .test)
        }
    }
}

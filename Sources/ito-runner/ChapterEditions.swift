import Foundation

/// The limits of the optional `get_chapter_editions` export: the numbers the plugin SDK applies to
/// each page, and the caps the runner puts on one whole traversal.
public enum ChapterEditionsLimits {
    /// The largest request `limit` and the most chapters one page may carry.
    public static let maxLimit = 100
    /// Bytes of a present cursor, in a request or as a page's `nextCursor`. Cursors are never empty.
    public static let maxCursorBytes = 4_096
    /// Exact chapters one traversal collects.
    public static let maxRows = 20_000
    /// Pages one traversal fetches.
    public static let maxPages = 256
    /// Encoded bytes of every page of one traversal together.
    public static let maxCumulativeBytes = 16 * 1024 * 1024
}

extension ChapterEditionsLimits {
    /// The fewest bytes one encoded chapter takes: a one-byte key length, eight absent options
    /// before the kind, the kind, and three absent options after it.
    static let minChapterBytes = 13
}

/// A request for one page of alternative uploads of a manga or novel. Plugins read it in this
/// layout; it is the `ChapterEditionsRequest` of the plugin SDK.
public struct ChapterEditionsRequest: Codable, Sendable {
    /// The title, without its chapter list or catalog. Its key is exact.
    public var entry: MediaEntry
    /// The opaque `nextCursor` of the previous page, byte for byte; nil asks for the first page.
    public var cursor: String?
    /// The most chapters the page may hold, 1 to `ChapterEditionsLimits.maxLimit`.
    public var limit: UInt32

    public init(entry: MediaEntry, cursor: String? = nil, limit: UInt32) {
        self.entry = entry
        self.cursor = cursor
        self.limit = limit
    }
}

/// One page of alternative uploads answering a `ChapterEditionsRequest`. The editions are
/// ordinary ABI 3 chapters. `scope` stays constant through a traversal and `completeness` does
/// not: every page with a `nextCursor` is `partial`, the last one may be `unknown`, `partial` or
/// `complete`.
public struct ChapterEditionsPage: Codable, Sendable {
    public var editions: [Chapter]
    public var nextCursor: String?
    public var scope: CatalogScope
    public var completeness: CatalogCompleteness

    public init(
        editions: [Chapter], nextCursor: String? = nil, scope: CatalogScope = .unknown,
        completeness: CatalogCompleteness = .unknown
    ) {
        self.editions = editions
        self.nextCursor = nextCursor
        self.scope = scope
        self.completeness = completeness
    }
}

/// A broken rule of the chapter editions contract. It names the rule only, never the offending
/// value, and its description is a fixed code for logs; hosts show their own text. Chapter rules
/// stay `CatalogContractViolation`s.
public struct ChapterEditionsViolation: Error, Equatable, Sendable, CustomStringConvertible {
    /// The rules by their fixed codes. The first seven are the plugin SDK's; the `sequence` rules
    /// are the runner's alone, found across pages.
    public enum Rule: String, Sendable, CaseIterable {
        /// The request entry is not a manga or novel.
        case requestEntryKind = "request.entry_kind"
        /// The request limit is outside 1 to `ChapterEditionsLimits.maxLimit`.
        case requestLimit = "request.limit"
        /// A present request cursor is empty or longer than `ChapterEditionsLimits.maxCursorBytes`.
        case requestCursor = "request.cursor"
        /// A page's `nextCursor` is present but empty or too long.
        case pageCursor = "page.cursor"
        /// A page holds more chapters than the request limit.
        case pageCount = "page.count"
        /// A page with a `nextCursor` is not `partial`.
        case pageCompleteness = "page.completeness"
        /// A page with a `nextCursor` holds no chapters, so the traversal would not progress.
        case pageNoProgress = "page.no_progress"
        /// A page offered a cursor an earlier page of the traversal already offered.
        case sequenceCursorRepeated = "sequence.cursor_repeated"
        /// A page reported another scope than the first page.
        case sequenceScopeChanged = "sequence.scope_changed"

        /// Whether only hosts report this rule: a plugin never does.
        public var isHostOnly: Bool {
            switch self {
            case .sequenceCursorRepeated, .sequenceScopeChanged: return true
            default: return false
            }
        }
    }

    public let rule: Rule

    public init(_ rule: Rule) {
        self.rule = rule
    }

    /// The violation a plugin reported with `code`, when it names a rule plugins report.
    init?(reportedCode code: String) {
        guard let rule = Rule(rawValue: code), !rule.isHostOnly else { return nil }
        self.rule = rule
    }

    public var description: String { rule.rawValue }
}

/// What a whole traversal of `ItoRunner.getChapterEditions` collected, after every page passed
/// the runner's checks.
public struct ChapterEditionsResult: Sendable {
    /// The cap that ended a traversal without publishing exhaustive coverage.
    public enum Bound: Sendable, Equatable {
        case rows, pages, bytes
    }

    public enum Termination: Sendable, Equatable {
        /// The source offered no further page.
        case exhausted
        /// The runner stopped at a cap. The collected pages are valid, but exhaustive coverage
        /// is not claimed: `completeness` is `partial`.
        case bounded(Bound)
    }

    /// The exact uploads, in the order the pages gave them. Unique by exact key.
    public let editions: [Chapter]
    /// The one scope every page reported.
    public let scope: CatalogScope
    /// The last page's completeness after an exhausted traversal; `partial` after a bounded one.
    /// `complete` says the traversal covered everything within `scope`, no more.
    public let completeness: CatalogCompleteness
    public let termination: Termination
    /// Pages whose chapters are in `editions`.
    public let pageCount: Int
    /// Encoded bytes of those pages.
    public let encodedBytes: Int
}

extension NetworkOperationContext {
    /// This context for another invocation of the same operation.
    func withGeneration(_ generation: UUID) -> NetworkOperationContext {
        NetworkOperationContext(
            purpose: purpose, sourceID: sourceID, authorizationScope: authorizationScope,
            operationID: operationID, batchID: batchID, policyRevision: policyRevision,
            generation: generation, scopedGrant: scopedGrant)
    }
}

extension MediaEntry {
    /// This entry without its chapter list and the catalog describing it, as an editions request
    /// carries it.
    func withoutChapters() -> MediaEntry {
        switch self {
        case .manga(var manga):
            manga.chapters = nil
            manga.catalog = nil
            return .manga(manga)
        case .novel(var novel):
            novel.chapters = nil
            novel.catalog = nil
            return .novel(novel)
        case .anime:
            return self
        }
    }
}

/// The rules one request or one page obeys on its own, in the order the plugin SDK checks them.
/// Strings are compared as exact UTF-8 bytes.
enum ChapterEditionsValidation {
    static func cursorWithinBounds(_ cursor: String) -> Bool {
        (1...ChapterEditionsLimits.maxCursorBytes).contains(cursor.utf8.count)
    }

    /// A manga or novel entry, a limit of 1 to 100 and a present cursor of 1 to 4096 bytes.
    static func request(_ request: ChapterEditionsRequest) throws {
        if case .anime = request.entry { throw ChapterEditionsViolation(.requestEntryKind) }
        guard (1...UInt32(ChapterEditionsLimits.maxLimit)).contains(request.limit) else {
            throw ChapterEditionsViolation(.requestLimit)
        }
        if let cursor = request.cursor, !cursorWithinBounds(cursor) {
            throw ChapterEditionsViolation(.requestCursor)
        }
    }

    /// The shape of one page answering a request with this `limit`: its cursor, chapter count,
    /// completeness, progress, then the chapters (see `CatalogValidation.chapters`).
    static func page(_ page: ChapterEditionsPage, limit: UInt32) throws {
        let continues: Bool
        if let cursor = page.nextCursor {
            guard cursorWithinBounds(cursor) else { throw ChapterEditionsViolation(.pageCursor) }
            continues = true
        } else {
            continues = false
        }
        guard page.editions.count <= Int(limit) else { throw ChapterEditionsViolation(.pageCount) }
        if continues && page.completeness != .partial { throw ChapterEditionsViolation(.pageCompleteness) }
        if continues && page.editions.isEmpty { throw ChapterEditionsViolation(.pageNoProgress) }
        try CatalogValidation.chapters(page.editions)
    }
}

/// The checks across the pages of one traversal, and what they add up to. Each page is shaped
/// right, as `ChapterEditionsValidation.page` says, and also:
///
/// - the scope is the first page's;
/// - no exact key repeats, within or across pages, and an identifier names one group name;
/// - no cursor repeats, so a source cannot send the traversal in a circle;
/// - the traversal stays within the caps of `ChapterEditionsLimits`. Reaching one ends it as
///   `bounded`, never as complete.
///
/// Any thrown violation ends the traversal and nothing of it is kept. Bytes are counted once, from
/// each page as it arrives.
struct ChapterEditionsSequence {
    enum Step: Equatable {
        /// Ask for the next page with this cursor.
        case next(cursor: String)
        case finished(ChapterEditionsResult.Termination)
    }

    let limit: UInt32
    private(set) var pageCount = 0
    private var editions: [Chapter] = []
    private(set) var encodedBytes = 0
    private var scope: CatalogScope?
    private var completeness: CatalogCompleteness = .unknown
    private var termination: ChapterEditionsResult.Termination = .exhausted
    private var keys = Set<ExactBytes>()
    private var groups: [ExactBytes: ExactBytes] = [:]
    private var cursors = Set<ExactBytes>()

    init(limit: UInt32) {
        self.limit = limit
    }

    /// Checks `page`, which came as `encodedBytes` bytes, against the pages before it.
    mutating func accept(_ page: ChapterEditionsPage, encodedBytes pageBytes: Int) throws -> Step {
        try ChapterEditionsValidation.page(page, limit: limit)
        if let scope {
            guard scope == page.scope else { throw ChapterEditionsViolation(.sequenceScopeChanged) }
        } else {
            scope = page.scope
        }
        for item in page.editions {
            guard keys.insert(ExactBytes(item.key)).inserted else {
                throw CatalogContractViolation(.duplicateKey)
            }
        }
        for item in page.editions {
            guard let id = item.scanlatorID, let name = item.scanlator else { continue }
            let identifier = ExactBytes(id), displayName = ExactBytes(name)
            if let known = groups[identifier] {
                guard known == displayName else { throw CatalogContractViolation(.scanlatorConflict) }
            } else {
                groups[identifier] = displayName
            }
        }
        if let cursor = page.nextCursor {
            guard cursors.insert(ExactBytes(cursor)).inserted else {
                throw ChapterEditionsViolation(.sequenceCursorRepeated)
            }
        }

        // A page is taken whole or not at all.
        if editions.count + page.editions.count > ChapterEditionsLimits.maxRows {
            return stop(at: .rows)
        }
        if encodedBytes + pageBytes > ChapterEditionsLimits.maxCumulativeBytes {
            return stop(at: .bytes)
        }
        editions.append(contentsOf: page.editions)
        encodedBytes += pageBytes
        pageCount += 1
        completeness = page.completeness
        if pageCount >= ChapterEditionsLimits.maxPages { return stop(at: .pages) }
        if editions.count >= ChapterEditionsLimits.maxRows { return stop(at: .rows) }
        if encodedBytes >= ChapterEditionsLimits.maxCumulativeBytes { return stop(at: .bytes) }
        guard let cursor = page.nextCursor else { return .finished(.exhausted) }
        return .next(cursor: cursor)
    }

    mutating func stop(at bound: ChapterEditionsResult.Bound) -> Step {
        termination = .bounded(bound)
        completeness = .partial
        return .finished(termination)
    }

    /// What was collected, once `accept` has said `finished`.
    func result() -> ChapterEditionsResult {
        ChapterEditionsResult(
            editions: editions, scope: scope ?? .unknown, completeness: completeness,
            termination: termination, pageCount: pageCount, encodedBytes: encodedBytes)
    }
}

import Foundation

/// The limits of the chapter catalog contract, the same numbers the plugin SDK applies before it
/// encodes a response. Every length is in UTF-8 bytes.
public enum CatalogLimits {
    /// Chapters in one entry's list.
    public static let chapters = 20_000
    /// A chapter key is never empty.
    public static let keyBytes = 512
    public static let titleBytes = 1_024
    /// A scanlator name is never empty.
    public static let scanlatorNameBytes = 256
    /// A present scanlator or logical unit identifier is never empty.
    public static let idBytes = 256
    /// A present revision is never empty.
    public static let revisionBytes = 256
    public static let urlBytes = 4_096
    public static let langBytes = 35
    /// Largest magnitude of a volume or chapter number: finite as a `Float` and safe to convert
    /// to an `Int`.
    public static let maxAbsNumber = 1e9
    /// Largest magnitude of `dateUpdated`, in seconds since 1970-01-01 UTC.
    public static let maxAbsDate = 1e11
    /// Encoded size of a `get_media_update` or `handle_url` response.
    public static let responseBytes = 16 * 1024 * 1024
}

/// A broken chapter catalog rule. It names the rule only, never the offending value, and its
/// description is a fixed code for logs; hosts show their own text.
public struct CatalogContractViolation: Error, Equatable, Sendable, CustomStringConvertible {
    /// The rules by their fixed codes, in the order they are checked.
    public enum Rule: String, Sendable, CaseIterable {
        case catalogWithoutChapters = "catalog.without_chapters"
        case countChapters = "count.chapters"
        case lengthKey = "length.key"
        case lengthTitle = "length.title"
        case lengthScanlatorName = "length.scanlator_name"
        case lengthScanlatorID = "length.scanlator_id"
        case lengthLogicalUnitID = "length.logical_unit_id"
        case lengthRevision = "length.revision"
        case lengthURL = "length.url"
        case lengthLang = "length.lang"
        case numberRange = "number.range"
        case numberDate = "number.date"
        case duplicateKey = "duplicate.key"
        case scanlatorConflict = "scanlator.conflict"
        case responseTooLarge = "response.too_large"
        /// A chapter kind this runner doesn't know. Only hosts report it.
        case enumUnknown = "enum.unknown"
        /// A plugin reported a violation under a code this runner doesn't list. The code is
        /// dropped, since it is plugin text.
        case unrecognized = "contract.unrecognized"
    }

    public let rule: Rule

    public init(_ rule: Rule) {
        self.rule = rule
    }

    /// The violation a plugin reported with `code`: the rule it names, or `.unrecognized` for any
    /// other text.
    init(reportedCode code: String) {
        self.rule = Rule(rawValue: code) ?? .unrecognized
    }

    public var description: String { rule.rawValue }
}

/// A string compared and hashed by its UTF-8 bytes alone, without the canonical equivalence Swift
/// gives `String`, and without copying the bytes out.
struct ExactBytes: Hashable {
    let value: String

    init(_ value: String) { self.value = value }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value.utf8.elementsEqual(rhs.value.utf8) }

    func hash(into hasher: inout Hasher) {
        for byte in value.utf8 { hasher.combine(byte) }
    }
}

/// Validates the chapter lists a plugin returned, in the order the SDK checks them, so both
/// sides report the same first violation. Strings are compared as exact UTF-8 bytes, without the
/// canonical equivalence Swift applies to `String`.
enum CatalogValidation {
    private static func require(_ condition: Bool, _ rule: CatalogContractViolation.Rule) throws {
        if !condition { throw CatalogContractViolation(rule) }
    }

    private static func bytes(_ value: String?, _ range: ClosedRange<Int>, _ rule: CatalogContractViolation.Rule) throws {
        guard let value else { return }
        try require(range.contains(value.utf8.count), rule)
    }

    private static func number(_ value: Double?, limit: Double, _ rule: CatalogContractViolation.Rule) throws {
        guard let value else { return }
        try require(value.isFinite && abs(value) <= limit, rule)
    }

    /// One chapter on its own; the list-wide rules are in `chapters(_:)`.
    static func chapter(_ chapter: Chapter) throws {
        try bytes(chapter.key, 1...CatalogLimits.keyBytes, .lengthKey)
        try bytes(chapter.title, 0...CatalogLimits.titleBytes, .lengthTitle)
        try bytes(chapter.scanlator, 1...CatalogLimits.scanlatorNameBytes, .lengthScanlatorName)
        try bytes(chapter.scanlatorID, 1...CatalogLimits.idBytes, .lengthScanlatorID)
        try bytes(chapter.logicalUnitID, 1...CatalogLimits.idBytes, .lengthLogicalUnitID)
        try bytes(chapter.revision, 1...CatalogLimits.revisionBytes, .lengthRevision)
        try bytes(chapter.url, 0...CatalogLimits.urlBytes, .lengthURL)
        try bytes(chapter.lang, 0...CatalogLimits.langBytes, .lengthLang)
        try number(chapter.volume, limit: CatalogLimits.maxAbsNumber, .numberRange)
        try number(chapter.chapter, limit: CatalogLimits.maxAbsNumber, .numberRange)
        try number(chapter.dateUpdated, limit: CatalogLimits.maxAbsDate, .numberDate)
    }

    /// One chapter list: its size, each chapter, unique keys and consistent group names.
    /// Duplicate `readingOrder` values are valid: equal values mean the same reading position.
    static func chapters(_ chapters: [Chapter]) throws {
        try require(chapters.count <= CatalogLimits.chapters, .countChapters)
        for item in chapters { try chapter(item) }
        var keys = Set<ExactBytes>(minimumCapacity: chapters.count)
        for item in chapters {
            try require(keys.insert(ExactBytes(item.key)).inserted, .duplicateKey)
        }
        var groups: [ExactBytes: ExactBytes] = [:]
        for item in chapters {
            guard let id = item.scanlatorID, let name = item.scanlator else { continue }
            let identifier = ExactBytes(id), displayName = ExactBytes(name)
            if let known = groups[identifier] {
                try require(known == displayName, .scanlatorConflict)
            } else {
                groups[identifier] = displayName
            }
        }
    }

    private static func list(_ chapters: [Chapter]?, hasCatalog: Bool) throws {
        guard let chapters else {
            try require(!hasCatalog, .catalogWithoutChapters)
            return
        }
        try Self.chapters(chapters)
    }

    static func manga(_ manga: Manga) throws {
        try list(manga.chapters, hasCatalog: manga.catalog != nil)
    }

    static func novel(_ novel: Novel) throws {
        try list(novel.chapters, hasCatalog: novel.catalog != nil)
    }

    /// The chapter list an entry carries; anime has none.
    static func entry(_ entry: MediaEntry) throws {
        switch entry {
        case .manga(let manga): try Self.manga(manga)
        case .novel(let novel): try Self.novel(novel)
        case .anime: break
        }
    }

    static func entries(_ entries: [MediaEntry]) throws {
        for item in entries { try entry(item) }
    }

    static func link(_ link: LinkValue) throws {
        switch link {
        case .manga(let manga): try Self.manga(manga)
        case .novel(let novel): try Self.novel(novel)
        case .url, .anime, .listing: break
        }
    }

    /// Every entry and chapter a home layout carries.
    static func home(_ home: HomeLayout) throws {
        for component in home.components {
            switch component.value {
            case .scroller(let entries, _), .mangaList(_, _, let entries, _), .bigScroller(let entries, _):
                for item in entries { try manga(item) }
            case .novelScroller(let entries, _), .novelList(_, _, let entries, _), .novelBigScroller(let entries, _):
                for item in entries { try novel(item) }
            case .mangaChapterList(_, let items, _):
                for item in items {
                    try manga(item.manga)
                    try chapter(item.chapter)
                }
            case .novelChapterList(_, let items, _):
                for item in items {
                    try novel(item.novel)
                    try chapter(item.chapter)
                }
            case .mediaScroller(let entries, _), .mediaList(_, _, let entries, _), .mediaBigScroller(let entries, _):
                try Self.entries(entries)
            case .animeScroller, .animeList, .animeEpisodeList, .animeBigScroller, .filters, .links:
                break
            }
        }
    }
}

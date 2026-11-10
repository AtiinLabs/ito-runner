import Foundation
import Testing
import WAT
@testable import ito_runner

private let encoder = ItoPostcardEncoder(abiVersion: 3)

private func chapters(_ keys: String...) -> [Chapter] {
    keys.map { Chapter(key: $0, kind: .images) }
}

private func manga(chapters: [Chapter]?, catalog: ChapterCatalog? = nil) -> Manga {
    Manga(key: "m", title: "M", chapters: chapters, catalog: catalog)
}

// MARK: - Validation rules

@Suite("Chapter catalog validation")
struct CatalogValidationTests {
    private func rule(_ chapter: Chapter) -> CatalogContractViolation.Rule? {
        do { try CatalogValidation.chapter(chapter); return nil }
        catch let violation as CatalogContractViolation { return violation.rule }
        catch { return .unrecognized }
    }

    private func rule(listing: [Chapter]) -> CatalogContractViolation.Rule? {
        do { try CatalogValidation.chapters(listing); return nil }
        catch let violation as CatalogContractViolation { return violation.rule }
        catch { return .unrecognized }
    }

    private func text(_ bytes: Int, _ character: Character = "x") -> String {
        String(repeating: character, count: bytes)
    }

    /// Each limit holds at its edge and breaks one past it, in UTF-8 bytes.
    @Test func everyLengthLimitIsExactlyItsEdge() {
        typealias Make = (String) -> Chapter
        let limits: [(String, ClosedRange<Int>, CatalogContractViolation.Rule, Make)] = [
            ("key", 1...512, .lengthKey, { Chapter(key: $0) }),
            ("title", 0...1_024, .lengthTitle, { Chapter(key: "k", title: $0) }),
            ("scanlator name", 1...256, .lengthScanlatorName, { Chapter(key: "k", scanlator: $0) }),
            ("scanlator id", 1...256, .lengthScanlatorID, { Chapter(key: "k", scanlator: "n", scanlatorID: $0) }),
            ("logical unit", 1...256, .lengthLogicalUnitID, { Chapter(key: "k", logicalUnitID: $0) }),
            ("revision", 1...256, .lengthRevision, { Chapter(key: "k", revision: $0) }),
            ("url", 0...4_096, .lengthURL, { Chapter(key: "k", url: $0) }),
            ("lang", 0...35, .lengthLang, { Chapter(key: "k", lang: $0) })
        ]
        for (name, range, violation, make) in limits {
            #expect(rule(make(text(range.lowerBound))) == nil, Comment(rawValue: "\(name) at its minimum"))
            #expect(rule(make(text(range.upperBound))) == nil, Comment(rawValue: "\(name) at its maximum"))
            #expect(rule(make(text(range.upperBound + 1))) == violation, Comment(rawValue: "\(name) past its maximum"))
            if range.lowerBound > 0 {
                #expect(rule(make("")) == violation, Comment(rawValue: "\(name) empty"))
            }
        }
    }

    @Test func lengthsCountBytesNotCharacters() {
        // 128 three-byte characters are 384 bytes, over a 256-byte name though only 128 characters.
        #expect(rule(Chapter(key: "k", scanlator: text(128, "€"))) == .lengthScanlatorName)
        #expect(rule(Chapter(key: "k", scanlator: text(85, "€"))) == nil)
        #expect(rule(Chapter(key: text(128, "😀"))) == nil)
        #expect(rule(Chapter(key: text(129, "😀"))) == .lengthKey)
    }

    @Test func numbersAreFiniteAndBoundedAndDatesHaveTheirOwnBound() {
        let number = { (value: Double) in Chapter(key: "k", volume: value) }
        #expect(rule(number(1e9)) == nil && rule(number(-1e9)) == nil && rule(number(0)) == nil)
        for bad in [1e9.nextUp, (-1e9).nextDown, .infinity, -.infinity, .nan, Double(Int64.max)] {
            #expect(rule(number(bad)) == .numberRange, Comment(rawValue: "\(bad)"))
            #expect(rule(Chapter(key: "k", chapter: bad)) == .numberRange, Comment(rawValue: "\(bad)"))
        }
        let date = { (value: Double) in Chapter(key: "k", dateUpdated: value) }
        #expect(rule(date(1e11)) == nil && rule(date(-1e11)) == nil && rule(date(2e9)) == nil)
        for bad in [1e11.nextUp, (-1e11).nextDown, .infinity, .nan] {
            #expect(rule(date(bad)) == .numberDate, Comment(rawValue: "\(bad)"))
        }
        // A volume this large is a date's size, not a number's.
        #expect(rule(number(1e10)) == .numberRange)
    }

    @Test func theCountLimitIsTwentyThousandChapters() {
        let list = { (count: Int) in (0..<count).map { Chapter(key: "k\($0)") } }
        #expect(rule(listing: list(20_000)) == nil)
        #expect(rule(listing: list(20_001)) == .countChapters)
        #expect(rule(listing: []) == nil)
    }

    @Test func keysAreUniqueAndOneGroupIdentifierHasOneName() {
        #expect(rule(listing: chapters("a", "b", "a")) == .duplicateKey)
        let group = { (key: String, name: String) in Chapter(key: key, scanlator: name, scanlatorID: "g") }
        #expect(rule(listing: [group("a", "Alpha"), group("b", "Alpha")]) == nil)
        #expect(rule(listing: [group("a", "Alpha"), group("b", "Beta")]) == .scanlatorConflict)
        // Without an identifier, two groups may share a name or differ freely.
        #expect(rule(listing: [Chapter(key: "a", scanlator: "Alpha"), Chapter(key: "b", scanlator: "Beta")]) == nil)
        // Different identifiers may carry the same name.
        #expect(rule(listing: [
            Chapter(key: "a", scanlator: "Alpha", scanlatorID: "g1"), Chapter(key: "b", scanlator: "Alpha", scanlatorID: "g2")
        ]) == nil)
    }

    /// The first broken rule in the SDK's order is the one reported, so both sides name the same one.
    @Test func theFirstViolationInTheDeclaredOrderWins() {
        let long = text(513)
        // A bad chapter beats a duplicate key, and a duplicate key beats a group conflict.
        #expect(rule(listing: [Chapter(key: "a", lang: text(40)), Chapter(key: "a")]) == .lengthLang)
        #expect(rule(listing: [Chapter(key: "a"), Chapter(key: "a"), Chapter(key: long)]) == .lengthKey)
        #expect(rule(listing: [
            Chapter(key: "a", scanlator: "A", scanlatorID: "g"), Chapter(key: "a", scanlator: "B", scanlatorID: "g")
        ]) == .duplicateKey)
        // Within one chapter: key, title, scanlator name, scanlator id, unit id, revision, url, lang, volume, chapter, date.
        let broken = Chapter(
            key: "k", title: text(2_000), volume: .nan, chapter: .nan, dateUpdated: .nan,
            scanlator: "", scanlatorID: "", url: text(5_000), lang: text(40), logicalUnitID: "", revision: "")
        #expect(rule(broken) == .lengthTitle)
        var next = broken
        next.title = nil
        #expect(rule(next) == .lengthScanlatorName)
        next.scanlator = "n"
        #expect(rule(next) == .lengthScanlatorID)
        next.scanlatorID = nil
        #expect(rule(next) == .lengthLogicalUnitID)
        next.logicalUnitID = nil
        #expect(rule(next) == .lengthRevision)
        next.revision = nil
        #expect(rule(next) == .lengthURL)
        next.url = nil
        #expect(rule(next) == .lengthLang)
        next.lang = nil
        #expect(rule(next) == .numberRange)
        next.volume = nil
        next.chapter = nil
        #expect(rule(next) == .numberDate)
        next.dateUpdated = nil
        #expect(rule(next) == nil)
    }

    @Test func aCatalogNeedsItsChaptersAndDuplicateReadingOrdersAreFine() throws {
        let catalog = ChapterCatalog(scope: .visible, completeness: .partial)
        #expect(throws: CatalogContractViolation(.catalogWithoutChapters)) {
            try CatalogValidation.entry(.manga(manga(chapters: nil, catalog: catalog)))
        }
        #expect(throws: CatalogContractViolation(.catalogWithoutChapters)) {
            try CatalogValidation.entry(.novel(Novel(key: "n", title: "N", chapters: nil, catalog: catalog)))
        }
        // An empty list is a list, and so may be complete.
        try CatalogValidation.entry(.manga(manga(chapters: [], catalog: ChapterCatalog(scope: .allEligible, completeness: .complete))))
        try CatalogValidation.entry(.manga(manga(chapters: nil)))
        try CatalogValidation.entry(.anime(Anime(key: "a", title: "A")))
        let ordered = [Chapter(key: "a", readingOrder: 1), Chapter(key: "b", readingOrder: 1)]
        try CatalogValidation.entry(.manga(manga(chapters: ordered, catalog: catalog)))
    }

    @Test func aViolationNamesItsRuleAndNeverTheValue() {
        let secret = "https://secret.example/\(text(5_000))"
        do { try CatalogValidation.chapter(Chapter(key: "k", url: secret)); Issue.record("accepted") }
        catch let violation as CatalogContractViolation {
            #expect(violation.rule == .lengthURL && violation.description == "length.url")
            #expect(!"\(violation)".contains("secret"))
        } catch { Issue.record("\(error)") }
    }
}

// MARK: - Through the runner

@Suite("Chapter catalog contract through the runner")
struct CatalogContractTests {
    private func runner(_ exports: String, responses: [(offset: Int, bytes: [UInt8])] = []) async throws -> ItoRunner {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: catalogPlugin(exports: exports, responses: responses))
        return runner
    }

    private func respond(_ export: String, parameters: String, with bytes: [UInt8]) async throws -> ItoRunner {
        try await runner("""
            (func (export "\(export)") \(parameters) (result i64)
              i64.const \(catalogPacked(catalogResponseOffset, bytes.count)))
            """, responses: [(catalogResponseOffset, bytes)])
    }

    private func violation(_ function: String, _ rule: CatalogContractViolation.Rule) -> ItoError {
        .catalogContractViolation(function: function, violation: CatalogContractViolation(rule))
    }

    // MARK: Every export that returns chapters

    private let duplicates = manga(chapters: chapters("a", "b", "a"))

    @Test func anUpdateWithDuplicateKeysIsRefused() async throws {
        let bytes = try encoder.encode(MediaEntry.manga(duplicates))
        let plugin = try await respond("get_media_update", parameters: "(param i32 i32 i32 i32)", with: bytes)
        await #expect(throws: violation("get_media_update", .duplicateKey)) {
            try await plugin.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        }
    }

    @Test func aListingAndASearchWithDuplicateKeysAreRefused() async throws {
        let page = MediaPageResult(entries: [.manga(Manga(key: "ok", title: "Fine")), .manga(duplicates)], hasNextPage: false)
        let bytes = try encoder.encode(page)
        let plugin = try await runner("""
            (func (export "get_listing") (param i32 i32 i32) (result i64)
              i64.const \(catalogPacked(catalogResponseOffset, bytes.count)))
            (func (export "search") (param i32 i32 i32 i32 i32 i32) (result i64)
              i64.const \(catalogPacked(catalogResponseOffset, bytes.count)))
            """, responses: [(catalogResponseOffset, bytes)])
        await #expect(throws: violation("get_listing", .duplicateKey)) {
            try await plugin.getListing(Listing(id: "l", name: "L", kind: 0), page: 1, context: .test)
        }
        await #expect(throws: violation("search", .duplicateKey)) {
            try await plugin.search(query: "q", page: 1, context: .test)
        }
    }

    @Test func aHomeWithABrokenEntryOrChapterIsRefused() async throws {
        let long = String(repeating: "k", count: 513)
        let layouts: [(HomeComponentValue, CatalogContractViolation.Rule)] = [
            (.scroller([duplicates], nil), .duplicateKey),
            (.mangaList(false, nil, [manga(chapters: nil, catalog: ChapterCatalog(scope: .visible))], nil), .catalogWithoutChapters),
            (.novelBigScroller([Novel(key: "n", title: "N", chapters: chapters("a", "a"))], nil), .duplicateKey),
            (.mediaScroller([.manga(duplicates)], nil), .duplicateKey),
            (.mangaChapterList(nil, [MangaWithChapter(manga: Manga(key: "m", title: "M"), chapter: Chapter(key: long, kind: .images))], nil),
                .lengthKey),
            (.novelChapterList(nil, [NovelWithChapter(novel: Novel(key: "n", title: "N"), chapter: Chapter(key: "", kind: .text))], nil),
                .lengthKey)
        ]
        for (component, rule) in layouts {
            let bytes = try encoder.encode(HomeLayout(components: [HomeComponent(value: component)]))
            let plugin = try await respond("get_home", parameters: "", with: bytes)
            await #expect(throws: violation("get_home", rule), Comment(rawValue: "\(rule)")) {
                try await plugin.getHome(context: .test)
            }
        }
    }

    @Test func aLinkWithABrokenEntryIsRefusedAndAnAcceptedOneIsReturned() async throws {
        let broken = try encoder.encode(LinkValue.manga(manga(chapters: nil, catalog: ChapterCatalog(scope: .visible))))
        let plugin = try await respond("handle_url", parameters: "(param i32 i32)", with: broken)
        await #expect(throws: violation("handle_url", .catalogWithoutChapters)) {
            try await plugin.handleUrl("https://example.test/m", context: .test)
        }
        let fine = try encoder.encode(LinkValue.novel(Novel(key: "n", title: "N", chapters: chapters("a", "b"))))
        let accepting = try await respond("handle_url", parameters: "(param i32 i32)", with: fine)
        guard case .novel(let novel)? = try await accepting.handleUrl("https://example.test/n", context: .test) else {
            Issue.record("expected a novel"); return
        }
        #expect(novel.chapters?.map(\.key) == ["a", "b"])
    }

    // MARK: Unknown kinds

    /// An entry of one manga with one chapter whose kind is `kind` on the wire.
    private func entry(withKind kind: UInt8) throws -> [UInt8] {
        var bytes = try encoder.encode(MediaEntry.manga(manga(chapters: chapters("c"))))
        // The kind precedes the three optional fields that end a chapter, and the absent catalog.
        bytes[bytes.count - 5] = kind
        return bytes
    }

    @Test func aChapterKindNobodyKnowsIsAViolationNotADecodingError() async throws {
        #expect(try entry(withKind: 0) == encoder.encode(MediaEntry.manga(manga(chapters: chapters("c")))))
        let bytes = try entry(withKind: 4)
        let plugin = try await respond("get_media_update", parameters: "(param i32 i32 i32 i32)", with: bytes)
        await #expect(throws: violation("get_media_update", .enumUnknown)) {
            try await plugin.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        }
        let page = try encoder.encode(MediaPageResult(entries: [.manga(manga(chapters: chapters("c")))], hasNextPage: false))
        var listing = page
        listing[listing.count - 6] = 4
        let lister = try await respond("get_listing", parameters: "(param i32 i32 i32)", with: listing)
        await #expect(throws: violation("get_listing", .enumUnknown)) {
            try await lister.getListing(Listing(id: "l", name: "L", kind: 0), page: 1, context: .test)
        }
    }

    // MARK: Violations a plugin reports

    private func reporting(_ message: String, category: PluginErrorCategory = .contractViolation, from export: String)
        async throws -> ItoRunner {
        let payload = try encoder.encode(PluginErrorPayload(category: category, message: message))
        return try await runner("""
            (func (export "ito_last_error") (result i64) i64.const \(catalogPacked(catalogResponseOffset, payload.count)))
            (func (export "get_media_update") (param i32 i32 i32 i32) (result i64) i64.const 0)
            (func (export "handle_url") (param i32 i32) (result i64) i64.const 0)
            """, responses: [(catalogResponseOffset, payload)])
    }

    /// Hosts that know the category read the fixed code a plugin sends, for every code the contract lists.
    @Test(arguments: CatalogContractViolation.Rule.allCases.filter { $0 != .unrecognized })
    func aViolationAPluginReportsIsReadByItsCode(_ rule: CatalogContractViolation.Rule) async throws {
        let plugin = try await reporting(rule.rawValue, from: "get_media_update")
        await #expect(throws: violation("get_media_update", rule)) {
            try await plugin.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        }
        // An optional export that reports one has failed; it has not declined to take part.
        await #expect(throws: violation("handle_url", rule)) {
            try await plugin.handleUrl("https://example.test", context: .test)
        }
    }

    @Test(arguments: ["", "duplicate.key ", "Duplicate.Key", "length.key: /Users/someone/secret.txt", "contract.unrecognized", "a\nb"])
    func anyOtherCodeIsAGenericViolationWhoseTextIsNeverKept(_ message: String) async throws {
        let plugin = try await reporting(message, from: "get_media_update")
        let thrown = await #expect(throws: ItoError.self) {
            try await plugin.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        }
        #expect(thrown == violation("get_media_update", .unrecognized))
        #expect(!(thrown?.errorDescription ?? "").contains("secret") && !"\(thrown as Any)".contains("secret"))
    }

    @Test func theDescriptionNeverShowsACodeToUsers() throws {
        for rule in CatalogContractViolation.Rule.allCases {
            let description = violation("get_media_update", rule).errorDescription ?? ""
            #expect(!description.contains(rule.rawValue), Comment(rawValue: rule.rawValue))
            #expect(description.contains("get_media_update"))
        }
    }

    @Test func theViolationCategoryIsOnTheWireAsEight() throws {
        #expect(PluginErrorCategory.contractViolation.rawValue == 8)
        // Zigzag 16: what the SDK writes for it.
        let payload = try encoder.encode(PluginErrorPayload(category: .contractViolation, message: "x"))
        #expect(payload == [16, 1, 0x78])
    }

    // MARK: Response budget

    private func freeing(_ length: Int, export: String, parameters: String) async throws -> ItoRunner {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wat2wasm("""
            (module
              (memory (export "memory") 1)
              (global $frees (mut i32) (i32.const 0))
              \(abi3Prelude())
              (func (export "alloc") (param i32) (result i32) i32.const 8192)
              (func (export "dealloc") (param i32 i32) global.get $frees i32.const 1 i32.add global.set $frees)
              (func (export "frees") (result i32) global.get $frees)
              (func (export "\(export)") \(parameters) (result i64) i64.const \(catalogPacked(1024, length))))
            """))
        return runner
    }

    @Test func aResponseOverSixteenMebibytesIsRefusedBeforeItIsRead() async throws {
        let budget = 16 * 1024 * 1024
        let update = try await freeing(budget + 1, export: "get_media_update", parameters: "(param i32 i32 i32 i32)")
        await #expect(throws: violation("get_media_update", .responseTooLarge)) {
            try await update.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        }
        // The entry sent and the response are both released, and no memory was read.
        #expect(try await update.executeExport("frees") == [.i32(2)])

        let link = try await freeing(budget + 1, export: "handle_url", parameters: "(param i32 i32)")
        await #expect(throws: violation("handle_url", .responseTooLarge)) {
            try await link.handleUrl("https://example.test", context: .test)
        }
        #expect(try await link.executeExport("frees") == [.i32(2)])
    }

    /// At the budget the response is within it; what is left to fail is reading memory the plugin doesn't have.
    @Test func aResponseOfExactlyTheBudgetPassesTheCheck() async throws {
        let budget = 16 * 1024 * 1024
        let update = try await freeing(budget, export: "get_media_update", parameters: "(param i32 i32 i32 i32)")
        await #expect(throws: ItoError.memoryOutOfBounds(offset: 1024, length: budget, memorySize: 65_536)) {
            try await update.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        }
        let link = try await freeing(budget, export: "handle_url", parameters: "(param i32 i32)")
        await #expect(throws: ItoError.memoryOutOfBounds(offset: 1024, length: budget, memorySize: 65_536)) {
            try await link.handleUrl("https://example.test", context: .test)
        }
    }

    /// Other exports keep the budgets they had: a home isn't held to the update's.
    @Test func exportsWithoutACatalogBudgetAreNotHeldToIt() async throws {
        let home = try await freeing(16 * 1024 * 1024 + 1, export: "get_home", parameters: "")
        await #expect(throws: ItoError.memoryOutOfBounds(offset: 1024, length: 16 * 1024 * 1024 + 1, memorySize: 65_536)) {
            try await home.getHome(context: .test)
        }
    }
}

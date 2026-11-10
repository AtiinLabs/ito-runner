import Foundation
import Testing
@testable import ito_runner

/// `Fixtures/persisted-chapter-json.json`: blobs as Ito stored runner values before ABI 3, captured
/// from the models of the ABI 2 runner.
private struct PersistedFixture: Decodable {
    struct Blob: Decodable {
        let name: String
        let type: String
        let json: String
    }

    let blobs: [Blob]

    static func load() throws -> Self {
        let url = Bundle.module.url(forResource: "persisted-chapter-json", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func blob(_ name: String) throws -> Blob {
        try #require(blobs.first { $0.name == name }, "no blob \(name)")
    }
}

// MARK: - What an ABI 2 reader made of a blob

/// The decoding rules of the ABI 2 `Chapter`: numbers read as `Float`, the scanlator as a string,
/// every other key ignored.
private struct LegacyChapter: Decodable, Equatable {
    var key: String
    var title: String?
    var volume: Float?
    var chapter: Float?
    var dateUpdated: Double?
    var scanlator: String?
    var url: String?
    var lang: String?
    var paywalled: Bool?
    var kind: ContentKind?
}

private struct LegacyManga: Decodable, Equatable {
    var key: String
    var title: String
    var authors: [String]?
    var artist: String?
    var description: String?
    var tags: [String]?
    var cover: String?
    var url: String?
    var status: Manga.Status
    var contentRating: ContentRating
    var nsfw: Int32
    var viewer: Manga.Viewer
    var chapters: [LegacyChapter]?
}

private struct LegacyNovel: Decodable, Equatable {
    var key: String
    var title: String
    var authors: [String]?
    var status: Novel.Status
    var contentRating: ContentRating
    var nsfw: Int32
    var chapters: [LegacyChapter]?
}

/// The JSON a blob stands for, to compare stored shapes without depending on key order.
private func object(_ json: String) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
}

private func reEncoded<T: Codable>(_ type: T.Type, _ json: String) throws -> String {
    String(decoding: try JSONEncoder().encode(try JSONDecoder().decode(type, from: Data(json.utf8))), as: UTF8.self)
}

@Suite("Persisted JSON from before ABI 3")
struct PersistedJSONTests {
    private let fixture = try! PersistedFixture.load()

    private func chapter(_ name: String) throws -> Chapter {
        try JSONDecoder().decode(Chapter.self, from: Data(try fixture.blob(name).json.utf8))
    }

    // MARK: Decoding

    @Test func chaptersFromTheABI1EraDecodeWithoutAKind() throws {
        let chapter = try chapter("chapter.abi1_era")
        #expect(chapter.key == "c-1" && chapter.title == "One" && chapter.kind == nil)
        #expect(chapter.volume == 2 && chapter.chapter == 12.5 && chapter.dateUpdated == 1_700_000_000)
        #expect(chapter.scanlator == "Alpha Scans" && chapter.scanlatorID == nil)
        #expect(chapter.url == "https://example.test/c/1" && chapter.lang == "en" && chapter.paywalled == false)
        #expect(chapter.logicalUnitID == nil && chapter.readingOrder == nil && chapter.revision == nil)
    }

    @Test func chaptersFromTheABI2EraKeepTheirKindAndOmittedFields() throws {
        let chapter = try chapter("chapter.abi2_era")
        #expect(chapter.key == "c-2" && chapter.title == "Two" && chapter.kind == .text)
        #expect(chapter.chapter == 10.1 && chapter.dateUpdated == 1_700_000_100.5)
        #expect(chapter.volume == nil && chapter.scanlator == nil && chapter.url == nil && chapter.lang == nil)
        #expect(chapter.paywalled == nil)
        let minimal = try self.chapter("chapter.minimal")
        #expect(minimal.key == "c-3" && minimal.title == nil && minimal.kind == nil && minimal.chapter == nil)
    }

    /// A number stored as a Float's text reads as the same decimal, now as a Double.
    @Test func numbersStoredAsFloatsReadAsTheirDecimal() throws {
        let chapter = try chapter("chapter.float_numbers")
        #expect(chapter.volume == 1.1 && chapter.chapter == 0.1 && chapter.kind == .images)
    }

    @Test func entriesFromTheABI2EraDecodeWithoutACatalog() throws {
        let manga = try JSONDecoder().decode(Manga.self, from: Data(fixture.blob("manga.with_chapters").json.utf8))
        #expect(manga.key == "m" && manga.title == "M" && manga.status == .Ongoing && manga.viewer == .Rtl)
        #expect(manga.authors == ["A"] && manga.tags == ["t"] && manga.catalog == nil)
        #expect(manga.chapters?.count == 1 && manga.chapters?[0].scanlator == "G" && manga.chapters?[0].kind == .images)

        let novel = try JSONDecoder().decode(Novel.self, from: Data(fixture.blob("novel.with_chapters").json.utf8))
        #expect(novel.key == "n" && novel.status == .Completed && novel.contentRating == .Suggestive)
        #expect(novel.catalog == nil && novel.chapters?.first?.title == "Nine" && novel.chapters?.first?.kind == .text)

        let bare = try JSONDecoder().decode(Manga.self, from: Data(fixture.blob("manga.without_chapters").json.utf8))
        #expect(bare.chapters == nil && bare.catalog == nil)

        let anime = try JSONDecoder().decode(Anime.self, from: Data(fixture.blob("anime.with_episodes").json.utf8))
        #expect(anime.episodes?.first?.episode == 1.5 && anime.episodes?.first?.lang == "ja")
    }

    // MARK: Re-encoding

    private func reEncode(_ blob: PersistedFixture.Blob) throws -> String {
        switch blob.type {
        case "Chapter": return try reEncoded(Chapter.self, blob.json)
        case "Manga": return try reEncoded(Manga.self, blob.json)
        case "Novel": return try reEncoded(Novel.self, blob.json)
        case "Anime": return try reEncoded(Anime.self, blob.json)
        default: throw ItoError.wasmTrap("unknown blob type \(blob.type)")
        }
    }

    /// What a legacy blob stands for must not grow keys or change values by being read and written,
    /// or every stored entry would change the first time the library touches it.
    @Test func readingAndWritingALegacyBlobChangesNoKeyAndNoValue() throws {
        for blob in fixture.blobs {
            #expect(try object(reEncode(blob)) == object(blob.json), Comment(rawValue: blob.name))
        }
    }

    /// An older build reading what this one wrote sees the same thing it saw before.
    @Test func whatIsWrittenBackIsStillReadableByTheOlderRules() throws {
        for blob in fixture.blobs {
            let rewritten = Data(try reEncode(blob).utf8), original = Data(blob.json.utf8)
            let decoder = JSONDecoder()
            switch blob.type {
            case "Chapter":
                #expect(try decoder.decode(LegacyChapter.self, from: rewritten)
                    == decoder.decode(LegacyChapter.self, from: original), Comment(rawValue: blob.name))
            case "Manga":
                #expect(try decoder.decode(LegacyManga.self, from: rewritten)
                    == decoder.decode(LegacyManga.self, from: original), Comment(rawValue: blob.name))
            case "Novel":
                #expect(try decoder.decode(LegacyNovel.self, from: rewritten)
                    == decoder.decode(LegacyNovel.self, from: original), Comment(rawValue: blob.name))
            default:
                break
            }
        }
    }

    // MARK: What ABI 3 adds

    private var richChapter: Chapter {
        Chapter(
            key: "c-9", title: "Nine", volume: 1, chapter: 10.0000001, dateUpdated: 1_700_000_000.5,
            scanlator: "Alpha Scans", scanlatorID: "g-1", url: "https://example.test/c/9", lang: "en",
            paywalled: true, kind: .images, logicalUnitID: "lu-9", readingOrder: -7, revision: "r3")
    }

    /// New keys are additive and optional, and an older reader ignores them.
    @Test func whatABI3AddsIsAdditiveToTheStoredShape() throws {
        let stored = String(decoding: try JSONEncoder().encode(richChapter), as: UTF8.self)
        let keys = Set(try object(stored).allKeys.map { "\($0)" })
        #expect(keys == [
            "key", "title", "volume", "chapter", "dateUpdated", "scanlator", "scanlatorId", "url", "lang",
            "paywalled", "kind", "logicalUnitId", "readingOrder", "revision"
        ])

        let legacy = try JSONDecoder().decode(LegacyChapter.self, from: Data(stored.utf8))
        #expect(legacy.scanlator == "Alpha Scans" && legacy.kind == .images && legacy.key == "c-9")
        // Numbers an older reader holds as a Float are the nearest ones, and still in range.
        #expect(legacy.chapter == Float(10.0000001))
    }

    @Test func aNewBlobReadsBackAsWritten() throws {
        let stored = try JSONEncoder().encode(richChapter)
        let read = try JSONDecoder().decode(Chapter.self, from: stored)
        #expect(read.scanlator == "Alpha Scans" && read.scanlatorID == "g-1")
        #expect(read.chapter == 10.0000001 && read.volume == 1 && read.dateUpdated == 1_700_000_000.5)
        #expect(read.logicalUnitID == "lu-9" && read.readingOrder == -7 && read.revision == "r3")
        #expect(read.kind == .images && read.paywalled == true)
    }

    @Test func aCatalogIsStoredAsItsTwoRawValues() throws {
        let manga = Manga(
            key: "m", title: "M", chapters: [Chapter(key: "c", kind: .text)],
            catalog: ChapterCatalog(scope: .allEligible, completeness: .partial))
        let stored = try JSONEncoder().encode(manga)
        #expect(try object(String(decoding: stored, as: UTF8.self))["catalog"] as? NSDictionary
            == ["scope": 2, "completeness": 1])
        #expect(try JSONDecoder().decode(Manga.self, from: stored).catalog
            == ChapterCatalog(scope: .allEligible, completeness: .partial))
        let novel = try JSONDecoder().decode(
            Novel.self, from: Data(#"{"key":"n","title":"N","status":0,"contentRating":0,"nsfw":0,"catalog":{"scope":1,"completeness":2}}"#.utf8))
        #expect(novel.catalog == ChapterCatalog(scope: .visible, completeness: .complete))
    }

    /// A blob written by a later release that knows more scopes still reads, as unknown.
    @Test func aStoredCatalogWithAnUnknownValueReadsAsUnknown() throws {
        let json = #"{"key":"m","title":"M","status":0,"contentRating":0,"nsfw":0,"viewer":0,"catalog":{"scope":9,"completeness":-4}}"#
        let manga = try JSONDecoder().decode(Manga.self, from: Data(json.utf8))
        #expect(manga.catalog == ChapterCatalog(scope: .unknown, completeness: .unknown))
        let known = #"{"key":"m","title":"M","status":0,"contentRating":0,"nsfw":0,"viewer":0,"catalog":{"scope":2,"completeness":99}}"#
        #expect(try JSONDecoder().decode(Manga.self, from: Data(known.utf8)).catalog
            == ChapterCatalog(scope: .allEligible, completeness: .unknown))
    }

    /// A kind the runner doesn't know is not guessed at when it is read back from storage.
    @Test func aStoredKindOfAnotherNameStaysAnError() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Chapter.self, from: Data(#"{"key":"c","kind":"comic"}"#.utf8))
        }
    }

    /// The group's name keeps its key, so a blob with only a name reads as a group without an identifier.
    @Test func aStoredScanlatorNameWithoutAnIdentifierHasNone() throws {
        let read = try JSONDecoder().decode(Chapter.self, from: Data(#"{"key":"c","scanlator":"Group"}"#.utf8))
        #expect(read.scanlator == "Group" && read.scanlatorID == nil)
        let stored = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(try object(stored) == ["key": "c", "scanlator": "Group"])
    }
}

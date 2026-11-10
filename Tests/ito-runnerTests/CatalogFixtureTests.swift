import CryptoKit
import Foundation
import Testing
import WasmKit
@testable import ito_runner

/// `Fixtures/catalog-v3.json`, shared with the plugin SDK: every wire layout and verdict of the
/// ABI 3 chapter catalog contract. See `Fixtures/catalog-v3.origin.txt` for where it comes from.
private struct CatalogFixture: Decodable {
    struct Limits: Decodable {
        let max_chapters: Int
        let max_key_bytes: Int
        let max_title_bytes: Int
        let max_scanlator_name_bytes: Int
        let max_id_bytes: Int
        let max_revision_bytes: Int
        let max_url_bytes: Int
        let max_lang_bytes: Int
        let max_abs_number: Double
        let max_abs_date: Double
        let max_response_bytes: Int
    }

    struct Wire: Decodable {
        let name: String
        let type: String
        let direction: String
        let hex: String
        let repeat_hex: String?
        let repeat_count: Int?
        let suffix_hex: String?
        let expect: String
        let canonical_hex: String?

        /// Prefix, then the repeated part `repeat_count` times, then the suffix.
        var bytes: [UInt8] {
            var result = decodeHex(hex)
            if let repeat_hex, let repeat_count {
                let unit = decodeHex(repeat_hex)
                result.reserveCapacity(result.count + unit.count * repeat_count)
                for _ in 0..<repeat_count { result += unit }
            }
            return result + decodeHex(suffix_hex ?? "")
        }

        var canonicalBytes: [UInt8] { canonical_hex.map { decodeHex($0) } ?? bytes }

        /// The code of the violation the host must report, when it must.
        var violation: String? {
            expect.hasPrefix("violation:") ? String(expect.dropFirst("violation:".count)) : nil
        }
    }

    let contract: String
    let version: Int
    let codes: [String]
    let limits: Limits
    let wire: [Wire]

    static let url = Bundle.module.url(forResource: "catalog-v3", withExtension: "json", subdirectory: "Fixtures")!
    static let shared = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))

    func wire(_ name: String) -> Wire { wire.first { $0.name == name }! }
}

private let decoder = ItoPostcardDecoder(abiVersion: 3)
private let encoder = ItoPostcardEncoder(abiVersion: 3)

/// What a host makes of a case's bytes: decoding them, then the catalog rules, as the runner does.
private func verdict(_ wire: CatalogFixture.Wire) -> String {
    do {
        let bytes = wire.bytes
        switch wire.type {
        case "Chapter":
            try CatalogValidation.chapter(try decoder.decode(Chapter.self, from: bytes))
        case "MediaEntry":
            try CatalogValidation.entry(try decoder.decode(MediaEntry.self, from: bytes))
        case "Vec<Page>":
            _ = try decoder.decode([Page].self, from: bytes)
        case "ErrorReport":
            let report = try decoder.decode(PluginErrorPayload.self, from: bytes)
            guard report.category == .contractViolation,
                  CatalogContractViolation(reportedCode: report.message).rule != .unrecognized else {
                return "unaccepted report"
            }
        default:
            return "unknown type \(wire.type)"
        }
        return "ok"
    } catch let violation as CatalogContractViolation {
        return "violation:\(violation.rule.rawValue)"
    } catch {
        return "decode_error"
    }
}

@Suite("Chapter catalog fixtures shared with the plugin SDK")
struct CatalogFixtureTests {
    private let fixture = CatalogFixture.shared

    /// The copy is the one the SDK pinned, byte for byte, so the two suites assert the same thing.
    @Test func theFixtureIsTheOneTheSDKPinned() throws {
        let digest = SHA256.hash(data: try Data(contentsOf: CatalogFixture.url))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "325b31664ea48dcf82242501346b5f09402ea1dd0b43d8156a63ba8d1ad5a8e4")
        #expect(fixture.contract == "ito-catalog" && fixture.version == 3)
    }

    @Test func theLimitsAreTheFixturesLimits() {
        let limits = fixture.limits
        #expect(CatalogLimits.chapters == limits.max_chapters)
        #expect(CatalogLimits.keyBytes == limits.max_key_bytes)
        #expect(CatalogLimits.titleBytes == limits.max_title_bytes)
        #expect(CatalogLimits.scanlatorNameBytes == limits.max_scanlator_name_bytes)
        #expect(CatalogLimits.idBytes == limits.max_id_bytes)
        #expect(CatalogLimits.revisionBytes == limits.max_revision_bytes)
        #expect(CatalogLimits.urlBytes == limits.max_url_bytes)
        #expect(CatalogLimits.langBytes == limits.max_lang_bytes)
        #expect(CatalogLimits.maxAbsNumber == limits.max_abs_number)
        #expect(CatalogLimits.maxAbsDate == limits.max_abs_date)
        #expect(CatalogLimits.responseBytes == limits.max_response_bytes)
    }

    /// The plugin reports a violation by one of these codes and nothing else.
    @Test func everyListedCodeIsARuleAndEveryRuleButTheCatchAllIsListed() {
        let rules = CatalogContractViolation.Rule.allCases.filter { $0 != .unrecognized }.map(\.rawValue)
        #expect(rules == fixture.codes)
    }

    @Test func everyCaseHasTheVerdictTheFixtureGives() {
        for wire in fixture.wire {
            #expect(verdict(wire) == wire.expect, Comment(rawValue: wire.name))
        }
    }

    @Test func theFixtureCoversEveryRuleAndEveryKindOfEntry() {
        let violations = Set(fixture.wire.compactMap(\.violation))
        // Hosts alone report enum.unknown; a plugin's own report of the others is its error.contract_violation case.
        #expect(violations == Set(fixture.codes).subtracting(["response.too_large"]))
        #expect(Set(fixture.wire.filter { $0.type == "MediaEntry" }.map { $0.bytes[0] }) == [0, 1, 2])
    }

    /// What the host decodes from an accepted case is re-encoded to the same bytes, or to the
    /// canonical ones where the case says it is accepted as written but not canonical.
    @Test func everyAcceptedCaseReEncodesToItsCanonicalBytes() throws {
        for wire in fixture.wire where wire.expect == "ok" {
            let bytes = wire.bytes
            let reEncoded: [UInt8]
            switch wire.type {
            case "Chapter": reEncoded = try encoder.encode(try decoder.decode(Chapter.self, from: bytes))
            case "MediaEntry": reEncoded = try encoder.encode(try decoder.decode(MediaEntry.self, from: bytes))
            case "Vec<Page>": reEncoded = try encoder.encode(try decoder.decode([Page].self, from: bytes))
            case "ErrorReport": reEncoded = try encoder.encode(try decoder.decode(PluginErrorPayload.self, from: bytes))
            default: Issue.record("unknown type \(wire.type)"); continue
            }
            #expect(reEncoded == wire.canonicalBytes, Comment(rawValue: wire.name))
        }
    }

    @Test func aRepeatedCaseIsItsPrefixThenTheUnitThenTheSuffix() {
        let wire = fixture.wire("entry.manga.too_many_chapters")
        let unit = decodeHex(wire.repeat_hex!), prefix = decodeHex(wire.hex)
        #expect(wire.repeat_count == 20_001 && wire.suffix_hex == "00")
        #expect(wire.bytes.count == prefix.count + unit.count * 20_001 + 1)
        #expect(Array(wire.bytes[prefix.count..<prefix.count + unit.count]) == unit)
        #expect(Array(wire.bytes.suffix(unit.count + 1)) == unit + [0])
    }

    /// The 20 001 chapters also repeat one key, but the count is what is reported.
    @Test func theCountIsCheckedBeforeDuplicateKeys() throws {
        let wire = fixture.wire("entry.manga.too_many_chapters")
        let entry = try decoder.decode(MediaEntry.self, from: wire.bytes)
        guard case .manga(let manga) = entry else { Issue.record("not a manga"); return }
        #expect(manga.chapters?.count == 20_001)
        #expect(Set(manga.chapters!.map(\.key)).count == 1)
        #expect(throws: CatalogContractViolation(.countChapters)) { try CatalogValidation.entry(entry) }
    }

    // MARK: Values

    private func chapter(_ name: String) throws -> Chapter {
        try decoder.decode(Chapter.self, from: fixture.wire(name).bytes)
    }

    private func manga(_ name: String) throws -> Manga {
        guard case .manga(let manga) = try decoder.decode(MediaEntry.self, from: fixture.wire(name).bytes) else {
            throw ItoError.wasmTrap("\(name) is not a manga")
        }
        return manga
    }

    @Test func aMinimalChapterHasOnlyItsKeyAndKind() throws {
        let minimal = try chapter("chapter.minimal")
        #expect(minimal.key == "k" && minimal.kind == .text)
        #expect(minimal.title == nil && minimal.volume == nil && minimal.chapter == nil)
        #expect(minimal.dateUpdated == nil && minimal.scanlator == nil && minimal.scanlatorID == nil)
        #expect(minimal.url == nil && minimal.lang == nil && minimal.paywalled == nil)
        #expect(minimal.logicalUnitID == nil && minimal.readingOrder == nil && minimal.revision == nil)
    }

    @Test func aScanlatorIsItsNameAndItsIdentifierWhenThereIsOne() throws {
        let named = try chapter("chapter.scanlator_name_only")
        #expect(named.scanlator == "Alpha Scans" && named.scanlatorID == nil)
        let identified = try chapter("chapter.scanlator_with_id")
        #expect(identified.scanlator == "Alpha Scans" && identified.scanlatorID == "g-1")
    }

    @Test func aFullChapterCarriesEveryField() throws {
        let full = try chapter("chapter.full")
        #expect(full.key == "c-12.5" && full.title == "Chapter 12.5: Extra")
        #expect(full.volume == 3 && full.chapter == 12.5 && full.dateUpdated == 1_700_000_000.5)
        #expect(full.scanlator == "Alpha Scans" && full.scanlatorID == "g-1")
        #expect(full.url == "https://example.test/c/12-5" && full.lang == "en" && full.paywalled == true)
        #expect(full.kind == .images)
        #expect(full.logicalUnitID == "lu-12.5" && full.readingOrder == -7 && full.revision == "r3")
    }

    @Test func catalogsDecodeTheirScopeAndCompleteness() throws {
        let expected: [(String, ChapterCatalog?)] = [
            ("entry.manga.catalog_absent", nil),
            ("entry.manga.catalog_visible_partial", ChapterCatalog(scope: .visible, completeness: .partial)),
            ("entry.manga.catalog_all_eligible_complete", ChapterCatalog(scope: .allEligible, completeness: .complete)),
            ("entry.manga.catalog_unknown", ChapterCatalog(scope: .unknown, completeness: .unknown)),
            ("entry.manga.minimal", nil)
        ]
        for (name, catalog) in expected {
            #expect(try manga(name).catalog == catalog, Comment(rawValue: name))
        }
        guard case .novel(let novel) = try decoder.decode(
            MediaEntry.self, from: fixture.wire("entry.novel.catalog_all_eligible_complete").bytes) else {
            Issue.record("not a novel"); return
        }
        #expect(novel.catalog == ChapterCatalog(scope: .allEligible, completeness: .complete))
        #expect(novel.chapters?.map(\.key) == ["t1"])
    }

    /// A value a later release adds reads as unknown and goes back out as the canonical unknown.
    @Test func unknownScopesAndCompletenessesReadAsUnknown() throws {
        for name in ["entry.manga.unknown_scope", "entry.manga.unknown_completeness"] {
            let wire = fixture.wire(name)
            let read = try manga(name)
            // The unknown scope sits beside completeness 0; the unknown completeness beside scope 1.
            #expect(read.catalog == ChapterCatalog(
                scope: name.hasSuffix("scope") ? .unknown : .visible, completeness: .unknown),
                Comment(rawValue: name))
            #expect(try decoder.decode(MediaEntry.self, from: wire.bytes).kind == .manga)
            #expect(try encoder.encode(MediaEntry.manga(read)) == wire.canonicalBytes, Comment(rawValue: name))
            #expect(wire.canonicalBytes != wire.bytes)
        }
    }

    @Test func numbersKeepTheirDoublePrecision() throws {
        let collision = try manga("entry.manga.f64_collision")
        let numbers = collision.chapters!.compactMap(\.chapter)
        #expect(numbers.count == 2 && numbers[0] != numbers[1])
        #expect(Float(numbers[0]) == Float(numbers[1]), "the pair collides as a Float, not as a Double")
        #expect(numbers == [10.0000001, 10.0000002])
        let limit = try manga("entry.manga.number_at_limit").chapters![0]
        #expect(limit.volume == -CatalogLimits.maxAbsNumber && limit.chapter == CatalogLimits.maxAbsNumber)
    }

    @Test func readingOrderIsAHintThatMayBeAbsentDuplicatedOrExtreme() throws {
        let order = { try manga($0).chapters!.map(\.readingOrder) }
        #expect(try order("entry.manga.reading_order_present") == [1, 2])
        #expect(try order("entry.manga.reading_order_absent") == [nil, nil])
        #expect(try order("entry.manga.reading_order_duplicated") == [1, 1])
        #expect(try order("entry.manga.reading_order_newest_first") == [2, 1])
        #expect(try order("entry.manga.reading_order_extremes") == [Int64.min, Int64.max])
    }

    @Test func sameNumberFromDifferentGroupsAndSplitBonusChaptersKeepTheirIdentity() throws {
        let groups = try manga("entry.manga.same_number_different_groups").chapters!
        #expect(groups.map(\.chapter) == [10, 10, 10])
        #expect(groups.map(\.scanlatorID) == ["g-1", "g-2", nil])
        #expect(groups.map(\.scanlator) == ["Alpha Scans", "Beta Scans", "Unlisted Group"])
        let split = try manga("entry.manga.same_group_split_bonus").chapters!
        #expect(split.map(\.key) == ["a-5-1", "a-5-2", "a-5-bonus"])
        #expect(split.map(\.chapter) == [5, 5, 5])
        #expect(split.map(\.logicalUnitID) == [nil, nil, "lu-bonus-5"])
        let unnumbered = try manga("entry.manga.fractional_and_unnumbered").chapters!
        #expect(unnumbered.map(\.chapter) == [1, 1.5, nil, nil])
    }

    @Test func keysAndNamesAreExactBytesWithoutNormalization() throws {
        let keys = try manga("entry.manga.keys_nfc_nfd").chapters!.map(\.key)
        #expect(keys.count == 2)
        #expect(keys[0].utf8.count == 2 && keys[1].utf8.count == 3, "one code point against two")
        #expect(keys[0] == keys[1], "Swift considers the two strings equal; the contract does not")
        #expect(Array(keys[0].utf8) != Array(keys[1].utf8))
        // So the same scanlator identifier with the two spellings is a conflict, not one name.
        #expect(verdict(fixture.wire("entry.manga.scanlator_nfc_nfd_conflict")) == "violation:scanlator.conflict")
        // And a key of 128 four-byte characters is exactly 512 bytes, which is within the limit.
        #expect(verdict(fixture.wire("entry.manga.key_multibyte_at_limit")) == "ok")
        #expect(verdict(fixture.wire("entry.manga.key_multibyte_oversized")) == "violation:length.key")
    }

    @Test func anAnimeEntryKeepsItsEpisodes() throws {
        guard case .anime(let anime) = try decoder.decode(
            MediaEntry.self, from: fixture.wire("entry.anime.with_episode").bytes) else {
            Issue.record("not an anime"); return
        }
        #expect(anime.key == "a" && anime.episodes?.count == 1)
        #expect(anime.episodes?[0].key == "e1" && anime.episodes?[0].episode == 1.5)
        #expect(anime.episodes?[0].dateUpdated == 1_700_000_000 && anime.episodes?[0].lang == "ja")
    }

    @Test func privatePageHeadersSurviveTheRoundTrip() throws {
        let pages = try decoder.decode([Page].self, from: fixture.wire("pages.private_headers").bytes)
        #expect(pages.count == 1 && pages[0].headers == ["Referer": "https://example.test/"])
    }

    // MARK: Plugin to host and host to plugin

    /// Every case a plugin may send, through the runner's `get_media_update`: accepted entries come
    /// out as decoded, and each violation is reported under the case's code and the export's name.
    @Test func everyEntryAPluginMayReturnIsJudgedThroughTheRunner() async throws {
        for wire in fixture.wire where wire.type == "MediaEntry" && wire.direction != "host_to_plugin" {
            let bytes = wire.bytes
            let seed: MediaEntry = bytes[0] == 2 ? .novel(Novel(key: "n", title: "N"))
                : bytes[0] == 1 ? .anime(Anime(key: "a", title: "A")) : .manga(Manga(key: "m", title: "M"))
            let runner = ItoRunner()
            try await runner.loadPlugin(fromBytes: catalogPlugin(
                exports: """
                    (func (export "get_media_update") (param i32 i32 i32 i32) (result i64)
                      i64.const \(catalogPacked(catalogResponseOffset, bytes.count)))
                    """,
                responses: [(catalogResponseOffset, bytes)]))
            if let code = wire.violation {
                await #expect(
                    throws: ItoError.catalogContractViolation(
                        function: "get_media_update", violation: CatalogContractViolation(reportedCode: code)),
                    Comment(rawValue: wire.name)
                ) { try await runner.getMediaUpdate(seed, context: .test) }
            } else {
                let updated = try await runner.getMediaUpdate(seed, context: .test)
                #expect(try encoder.encode(updated) == wire.canonicalBytes, Comment(rawValue: wire.name))
            }
        }
    }

    @Test func everyPageListAPluginMayReturnReachesTheCaller() async throws {
        for wire in fixture.wire where wire.type == "Vec<Page>" {
            let bytes = wire.bytes
            let runner = ItoRunner()
            try await runner.loadPlugin(fromBytes: catalogPlugin(
                exports: """
                    (func (export "get_chapter_pages") (param i32 i32 i32 i32) (result i64)
                      i64.const \(catalogPacked(catalogResponseOffset, bytes.count)))
                    """,
                responses: [(catalogResponseOffset, bytes)]))
            let pages = try await runner.getChapterPages(
                entry: .manga(Manga(key: "m", title: "M")), chapter: Chapter(key: "c"), context: .test)
            #expect(try encoder.encode(pages) == bytes, Comment(rawValue: wire.name))
        }
    }

    /// The chapters and entries a host may send are laid out exactly as the fixture has them.
    @Test func theChaptersAndEntriesTheHostSendsAreTheFixturesBytes() async throws {
        for wire in fixture.wire where wire.expect == "ok" && wire.direction != "plugin_to_host" {
            let bytes = wire.bytes
            let runner = ItoRunner()
            try await runner.loadPlugin(fromBytes: catalogPlugin(exports: """
                (func (export "get_media_update") (param i32 i32 i32 i32) (result i64)
                  local.get 0 local.get 1 call $capture i64.const 0)
                (func (export "get_chapter_pages") (param i32 i32 i32 i32) (result i64)
                  local.get 2 local.get 3 call $capture i64.const 0)
                """))
            switch wire.type {
            case "MediaEntry":
                let entry = try decoder.decode(MediaEntry.self, from: bytes)
                _ = try? await runner.getMediaUpdate(entry, context: .test)
            case "Chapter":
                let chapter = try decoder.decode(Chapter.self, from: bytes)
                _ = try? await runner.getChapterPages(
                    entry: .manga(Manga(key: "m", title: "M")), chapter: chapter, context: .test)
            default:
                Issue.record("a \(wire.type) is not sent to a plugin"); continue
            }
            #expect(try await captured(by: runner) == bytes, Comment(rawValue: wire.name))
        }
    }

    /// The SDK clears the catalog it is given before calling a plugin, so a host that still sent it
    /// would be describing a list the plugin is about to replace.
    @Test func anEntryThatTravelsToThePluginCarriesNoCatalog() async throws {
        let catalog = ChapterCatalog(scope: .allEligible, completeness: .complete)
        let chapters = [Chapter(key: "c", kind: .text)]
        let entries: [MediaEntry] = [
            .manga(Manga(key: "m", title: "M", chapters: chapters, catalog: catalog)),
            .novel(Novel(key: "n", title: "N", chapters: chapters, catalog: catalog))
        ]
        for entry in entries {
            let runner = ItoRunner()
            try await runner.loadPlugin(fromBytes: catalogPlugin(exports: """
                (func (export "get_media_update") (param i32 i32 i32 i32) (result i64)
                  local.get 0 local.get 1 call $capture i64.const 0)
                """))
            _ = try? await runner.getMediaUpdate(entry, context: .test)

            let received = try decoder.decode(MediaEntry.self, from: try await captured(by: runner))
            switch received {
            case .manga(let manga): #expect(manga.catalog == nil && manga.chapters?.count == 1)
            case .novel(let novel): #expect(novel.catalog == nil && novel.chapters?.count == 1)
            case .anime: Issue.record("an anime came back")
            }
            #expect(received.key == entry.key)
        }
        // The caller's entry is a value: it still has the catalog it was loaded with.
        guard case .manga(let original) = entries[0] else { return }
        #expect(original.catalog == catalog)
    }

    @Test func withoutACatalogTheBytesAreTheFixturesHostToPluginCase() throws {
        let withCatalog = try decoder.decode(
            MediaEntry.self, from: fixture.wire("entry.manga.catalog_all_eligible_complete").bytes)
        let sent = try encoder.encode(withCatalog.withoutCatalog())
        #expect(sent == fixture.wire("entry.manga.host_to_plugin_no_catalog").bytes)
    }
}

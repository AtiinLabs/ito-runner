import CryptoKit
import Foundation
import Testing
@testable import ito_runner

/// `Fixtures/home-v2.json`, shared with the plugin SDK: the featured home component's wire layout,
/// its downgrade and its first-violation order. See `Fixtures/home-v2.origin.txt` for where it
/// comes from.
struct HomeFixture: Decodable {
    struct Wire: Decodable {
        let name: String
        let type: String
        let hex: String
        let expect: String
        let variant: Int?

        var bytes: [UInt8] { decodeHex(hex) }

        /// The code of the violation the host must report, when it must.
        var violation: String? {
            expect.hasPrefix("violation:") ? String(expect.dropFirst("violation:".count)) : nil
        }
    }

    struct Downgrade: Decodable {
        let name: String
        let features: UInt32
        let input: String
        let output: String
        let expect: String
    }

    let contract: String
    let version: Int
    let features: [String: UInt32]
    let codes: [String]
    let limits: [String: Double]
    let wire: [Wire]
    let downgrade: [Downgrade]

    static let url = Bundle.module.url(forResource: "home-v2", withExtension: "json", subdirectory: "Fixtures")!
    static let shared = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))

    func wire(_ name: String) -> Wire { wire.first { $0.name == name }! }
}

private let decoder = ItoPostcardDecoder(abiVersion: 3)
private let encoder = ItoPostcardEncoder(abiVersion: 3)

/// The layout a case's bytes are: a whole layout, or one component's value in a layout of its own.
private func layout(of wire: HomeFixture.Wire) throws -> HomeLayout {
    switch wire.type {
    case "HomeLayout":
        return try decoder.decode(HomeLayout.self, from: wire.bytes)
    case "HomeComponentValue":
        return HomeLayout(components: [HomeComponent(value: try decoder.decode(HomeComponentValue.self, from: wire.bytes))])
    default:
        throw ItoError.wasmTrap("unknown type \(wire.type)")
    }
}

/// What a host makes of `bytes`: decoding them, then the catalog rules, as the runner does.
private func verdict(_ bytes: [UInt8]) -> String {
    do {
        try CatalogValidation.home(try decoder.decode(HomeLayout.self, from: bytes))
        return "ok"
    } catch let violation as CatalogContractViolation {
        return "violation:\(violation.rule.rawValue)"
    } catch {
        return "decode_error"
    }
}

@Suite("Featured home fixtures shared with the plugin SDK")
struct HomeFixtureTests {
    private let fixture = HomeFixture.shared

    /// The copy is the one the SDK pinned, byte for byte, so the two suites assert the same thing.
    @Test func theFixtureIsTheOneTheSDKPinned() throws {
        let digest = SHA256.hash(data: try Data(contentsOf: HomeFixture.url))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == "3644aeaaa8920cbc9a62304daacace60a36a246cdf7e6829ae8c57ebc889654a")
        #expect(fixture.contract == "ito-home" && fixture.version == 3)
        #expect(fixture.features == ["featured": 1])
        #expect(ItoRunner.supportedHomeFeatures.rawValue == fixture.features["featured"])
        #expect(ItoRunner.supportedHomeFeatures == [.featured])
    }

    @Test func theLimitsAreTheFixturesLimits() {
        let limits = fixture.limits
        #expect(Double(CatalogLimits.featuredItems) == limits["max_featured_items"])
        #expect(Double(CatalogLimits.featuredChips) == limits["max_featured_chips"])
        #expect(Double(CatalogLimits.taglineBytes) == limits["max_tagline_bytes"])
        #expect(Double(CatalogLimits.summaryBytes) == limits["max_summary_bytes"])
        #expect(Double(CatalogLimits.badgeLabelBytes) == limits["max_badge_label_bytes"])
        #expect(Double(CatalogLimits.chipTextBytes) == limits["max_chip_text_bytes"])
        #expect(Double(CatalogLimits.maxBadgeRank) == limits["max_badge_rank"])
        #expect(Double(CatalogLimits.minAutoAdvance) == limits["min_auto_advance"])
        #expect(Double(CatalogLimits.maxAutoAdvance) == limits["max_auto_advance"])
        #expect(Double(CatalogLimits.maxAccent) == limits["max_accent"])
        #expect(CatalogLimits.minChipYear == limits["min_chip_year"])
        #expect(CatalogLimits.maxChipYear == limits["max_chip_year"])
        #expect(CatalogLimits.maxChipRating == limits["max_chip_rating"])
        #expect(CatalogLimits.maxChipUnits == limits["max_chip_units"])
        #expect(Double(CatalogLimits.urlBytes) == limits["max_url_bytes"])
    }

    @Test func everyNewCodeIsARuleAndIsPinnedByACase() {
        let rules = Set(CatalogContractViolation.Rule.allCases.map(\.rawValue))
        let pinned = Set(fixture.wire.compactMap(\.violation))
        #expect(fixture.codes.count == 5)
        for code in fixture.codes {
            #expect(rules.contains(code), Comment(rawValue: code))
            #expect(pinned.contains(code), Comment(rawValue: code))
        }
    }

    @Test func everyCaseHasTheVerdictTheFixtureGives() throws {
        #expect(!fixture.wire.isEmpty)
        for wire in fixture.wire {
            // A value case is checked inside a layout of one untitled component.
            let bytes = wire.type == "HomeLayout" ? wire.bytes : try encoder.encode(try layout(of: wire))
            #expect(verdict(bytes) == wire.expect, Comment(rawValue: wire.name))
        }
    }

    /// Variant 17 is the featured component, and nothing before it moved.
    @Test func theFeaturedVariantIsSeventeen() throws {
        let wire = fixture.wire("variant.featured")
        #expect(wire.variant == 17 && wire.bytes[0] == 17)
        guard case .featured(let component) = try decoder.decode(HomeComponentValue.self, from: wire.bytes) else {
            Issue.record("not a featured component"); return
        }
        #expect(component.items.count == 1)
        #expect(HomeComponentValue.CodingKeys.featured.rawValue == 17)
        #expect(HomeComponentValue.CodingKeys.mediaBigScroller.rawValue == 16)
    }

    /// What the host decodes from a case is re-encoded to the same bytes.
    @Test func everyCaseReEncodesToItsBytes() throws {
        for wire in fixture.wire {
            let reEncoded: [UInt8]
            switch wire.type {
            case "HomeLayout": reEncoded = try encoder.encode(try decoder.decode(HomeLayout.self, from: wire.bytes))
            case "HomeComponentValue": reEncoded = try encoder.encode(try decoder.decode(HomeComponentValue.self, from: wire.bytes))
            default: Issue.record("unknown type \(wire.type)"); continue
            }
            #expect(reEncoded == wire.bytes, Comment(rawValue: wire.name))
        }
    }

    // MARK: Downgrade

    /// A host with the featured bit gets the layout it was sent; a host without it never asks for
    /// one, since `getHome` always passes the bit. The lowered bytes are the SDK's to produce, and
    /// the runner has to read each of them as the layout it checks.
    @Test func everyDowngradeCaseReadsAndRewritesAsPinnedWithItsVerdict() throws {
        for item in fixture.downgrade {
            let input = decodeHex(item.input), output = decodeHex(item.output)
            #expect(try encoder.encode(try decoder.decode(HomeLayout.self, from: input)) == input, Comment(rawValue: item.name))
            #expect(try encoder.encode(try decoder.decode(HomeLayout.self, from: output)) == output, Comment(rawValue: item.name))
            #expect(verdict(output) == item.expect, Comment(rawValue: item.name))

            let features = HomeFeatures(rawValue: item.features)
            let lowered = try decoder.decode(HomeLayout.self, from: output)
            let hasFeatured = lowered.components.contains { if case .featured = $0.value { return true } else { return false } }
            if features.contains(.featured) {
                #expect(input == output, Comment(rawValue: item.name))
            } else {
                #expect(!hasFeatured, "a lowered layout carries no featured component: \(item.name)")
            }
        }
    }

    @Test func aHostThatCannotShowFeaturedWouldReadItsLoweredLayoutAsAnyBigScroller() throws {
        let bigScrollers = ["downgrade.manga_only", "downgrade.anime_only", "downgrade.novel_only", "downgrade.mixed"]
        for name in bigScrollers {
            let item = fixture.downgrade.first { $0.name == name }!
            let lowered = try decoder.decode(HomeLayout.self, from: decodeHex(item.output))
            #expect(lowered.components.count == 1, Comment(rawValue: name))
            switch (name, lowered.components[0].value) {
            case ("downgrade.manga_only", .bigScroller(let manga, _)): #expect(manga.count == 2)
            case ("downgrade.anime_only", .animeBigScroller(let anime, _)): #expect(anime.count == 2)
            case ("downgrade.novel_only", .novelBigScroller(let novels, _)): #expect(novels.count == 2)
            case ("downgrade.mixed", .mediaBigScroller(let entries, _)): #expect(entries.count == 3)
            default: Issue.record("unexpected lowering for \(name)")
            }
        }
    }

    // MARK: Values

    private func home(_ name: String) throws -> HomeLayout { try layout(of: fixture.wire(name)) }

    private func featuredComponent(_ name: String) throws -> (component: HomeComponent, featured: FeaturedComponent) {
        let component = try home(name).components[0]
        guard case .featured(let featured) = component.value else { throw ItoError.wasmTrap("\(name) is not featured") }
        return (component, featured)
    }

    @Test func theFullExampleCarriesEveryField() throws {
        let (component, featured) = try featuredComponent("home.featured.full")
        #expect(component.title == "Featured" && component.subtitle == nil)
        #expect(featured.autoAdvance == 8 && featured.listing?.id == "l" && featured.listing?.name == "All")
        #expect(featured.listing?.kind == 0)
        let item = try #require(featured.items.first)
        guard case .manga(let manga) = item.entry else { Issue.record("not a manga"); return }
        #expect(manga.key == "m1" && manga.cover == "https://example.test/m1.jpg")
        #expect(item.banner == "https://example.test/banner.jpg" && item.logo == "https://example.test/logo.png")
        #expect(item.tagline == "The legend returns" && item.summary == "A short summary.")
        #expect(item.badge?.kind == 2 && item.badge?.rank == 1 && item.badge?.label == nil)
        #expect(item.chips.map(\.kind) == [1, 2, 3, 4, 5])
        #expect(item.chips.map(\.number) == [2024, 8, 12, nil, nil])
        #expect(item.chips.map(\.text) == [nil, nil, nil, "Action", "Manhwa"])
        #expect(item.accent == 0xFF8800 && item.action == 1)
    }

    @Test func aMinimalItemHasOnlyItsEntry() throws {
        let (_, featured) = try featuredComponent("home.featured.minimal")
        #expect(featured.autoAdvance == nil && featured.listing == nil)
        let item = try #require(featured.items.first)
        #expect(item.banner == nil && item.logo == nil && item.tagline == nil && item.summary == nil)
        #expect(item.badge == nil && item.chips.isEmpty && item.accent == nil && item.action == 0)
    }

    @Test func entriesOfSeveralKindsAreOneFeaturedComponent() throws {
        let (_, featured) = try featuredComponent("home.featured.mixed_kinds")
        #expect(featured.items.map(\.entry.kind) == [.manga, .anime, .novel])
        // The same key under another kind is another page, not a duplicate.
        let (_, same) = try featuredComponent("home.featured.same_key_other_kind")
        #expect(same.items.count == 2 && Set(same.items.map(\.entry.key)).count == 1)
        #expect(Set(same.items.map(\.entry.kind)).count == 2)
    }

    /// A kind or action a later SDK adds is read as it is, and the home still passes: a chip or badge
    /// of an unknown kind is held to the length rules alone, and a host decides what to show.
    @Test func anUnknownChipBadgeOrActionDegradesInsteadOfFailingTheHome() throws {
        let item = FeaturedItem(
            entry: .manga(Manga(key: "m", title: "M")),
            badge: FeaturedBadge(kind: 99, rank: 1, label: "Hot"),
            chips: [
                FeaturedChip(kind: 99, number: 1e300, text: "Shown"),
                FeaturedChip(kind: -4, number: .nan, text: nil),
                FeaturedChip(kind: .max, number: nil, text: nil)
            ],
            action: .min)
        let layout = HomeLayout(components: [HomeComponent(value: .featured(FeaturedComponent(items: [item])))])
        let bytes = try encoder.encode(layout)
        #expect(verdict(bytes) == "ok")
        guard case .featured(let read) = try decoder.decode(HomeLayout.self, from: bytes).components[0].value else {
            Issue.record("not featured"); return
        }
        let page = read.items[0]
        #expect(page.action == .min && page.badge?.kind == 99 && page.badge?.label == "Hot")
        #expect(page.chips.map(\.kind) == [99, -4, .max])
        #expect(page.chips[0].text == "Shown" && page.chips[1].number?.isNaN == true)
        #expect(try encoder.encode(try decoder.decode(HomeLayout.self, from: bytes)) == bytes)
    }

    @Test func anUnknownKindIsStillHeldToTheLengthRules() throws {
        let long = String(repeating: "x", count: 65)
        let cases: [(FeaturedItem, CatalogContractViolation.Rule)] = [
            (FeaturedItem(entry: .manga(Manga(key: "m", title: "M")), chips: [FeaturedChip(kind: 99, text: "")]), .lengthText),
            (FeaturedItem(entry: .manga(Manga(key: "m", title: "M")), chips: [FeaturedChip(kind: 99, text: long)]), .lengthText),
            (FeaturedItem(entry: .manga(Manga(key: "m", title: "M")), badge: FeaturedBadge(kind: 99, label: long)), .lengthText),
            (FeaturedItem(entry: .manga(Manga(key: "m", title: "M")), badge: FeaturedBadge(kind: 99, rank: 0)), .numberRange)
        ]
        for (item, rule) in cases {
            #expect(throws: CatalogContractViolation(rule), Comment(rawValue: "\(rule)")) {
                try CatalogValidation.featured(FeaturedComponent(items: [item]))
            }
        }
    }

    // MARK: Rules

    private func rule(_ component: FeaturedComponent) -> CatalogContractViolation.Rule? {
        do { try CatalogValidation.featured(component); return nil }
        catch let violation as CatalogContractViolation { return violation.rule }
        catch { return .unrecognized }
    }

    private func page(_ key: String = "m", banner: String? = nil, logo: String? = nil, chips: [FeaturedChip] = []) -> FeaturedItem {
        FeaturedItem(entry: .manga(Manga(key: key, title: key)), banner: banner, logo: logo, chips: chips)
    }

    @Test func theSchemeIsHttpOrHttpsInAnyLetterCase() {
        for url in ["http://a", "https://a", "HTTP://a", "HtTpS://a"] {
            #expect(rule(FeaturedComponent(items: [page(banner: url)])) == nil, Comment(rawValue: url))
            #expect(rule(FeaturedComponent(items: [page(logo: url)])) == nil, Comment(rawValue: url))
        }
        for url in ["ftp://a", "//a", "https:/a", "httpx://a", "data:image/png;base64,AAAA", "javascript:1", " https://a", "a"] {
            #expect(rule(FeaturedComponent(items: [page(banner: url)])) == .urlScheme, Comment(rawValue: url))
            #expect(rule(FeaturedComponent(items: [page(logo: url)])) == .urlScheme, Comment(rawValue: url))
        }
    }

    /// Both artwork lengths are checked before either scheme.
    @Test func artworkLengthsComeBeforeSchemes() {
        let item = page(banner: "ftp://a", logo: "")
        #expect(rule(FeaturedComponent(items: [item])) == .lengthURL)
    }

    @Test func theChipRangesAreExactlyTheirEdges() {
        func chip(_ kind: Int32, _ number: Double) -> FeaturedComponent {
            FeaturedComponent(items: [page(chips: [FeaturedChip(kind: kind, number: number)])])
        }
        for (kind, accepted, refused): (Int32, [Double], [Double]) in [
            (1, [1800, 2024, 2200], [1799, 2201, 2024.5, .nan, .infinity]),
            (2, [0, 7.5, 10], [-0.1, 10.1, .nan, .infinity]),
            (3, [0, 12, 1_000_000], [-1, 1_000_001, 1.5, .nan, .infinity])
        ] {
            for number in accepted { #expect(rule(chip(kind, number)) == nil, Comment(rawValue: "\(kind) \(number)")) }
            for number in refused { #expect(rule(chip(kind, number)) == .numberRange, Comment(rawValue: "\(kind) \(number)")) }
        }
        // Kinds without a numeric meaning accept any number.
        for kind: Int32 in [0, 4, 5] { #expect(rule(chip(kind, -1e300)) == nil) }
    }

    @Test func autoAdvanceIsFiniteAndWithinItsBounds() {
        for seconds: Float32 in [2, 8, 60] {
            #expect(rule(FeaturedComponent(items: [page()], autoAdvance: seconds)) == nil)
        }
        for seconds: Float32 in [1.99, 60.01, 0, -3, .nan, .infinity] {
            #expect(rule(FeaturedComponent(items: [page()], autoAdvance: seconds)) == .numberRange)
        }
    }

    @Test func theAccentAndTheCountsHoldAtTheirEdges() {
        #expect(rule(FeaturedComponent(items: [])) == .countFeatured)
        #expect(rule(FeaturedComponent(items: (0..<20).map { page("m\($0)") })) == nil)
        #expect(rule(FeaturedComponent(items: (0..<21).map { page("m\($0)") })) == .countFeatured)
        let chips = (0..<7).map { _ in FeaturedChip(kind: 0, text: "t") }
        #expect(rule(FeaturedComponent(items: [page(chips: Array(chips.prefix(6)))])) == nil)
        #expect(rule(FeaturedComponent(items: [page(chips: chips)])) == .countChips)
        var item = page()
        item.accent = 0xFF_FFFF
        #expect(rule(FeaturedComponent(items: [item])) == nil)
        item.accent = 0x100_0000
        #expect(rule(FeaturedComponent(items: [item])) == .colorRange)
    }

    /// Items are identified by their exact bytes: two spellings of one name are two pages.
    @Test func duplicateKeysAreByKindAndExactBytes() {
        let composed = "\u{E9}", decomposed = "e\u{301}"
        #expect(composed == decomposed, "Swift treats the two spellings as one string")
        #expect(rule(FeaturedComponent(items: [page(composed), page(decomposed)])) == nil)
        #expect(rule(FeaturedComponent(items: [page("a"), page("b"), page("a")])) == .duplicateKey)
        let anime = FeaturedItem(entry: .anime(Anime(key: "a", title: "A")))
        #expect(rule(FeaturedComponent(items: [page("a"), anime])) == nil)
    }

    /// Items before duplicates, auto advance before items, the count before both.
    @Test func theFirstViolationIsInTheOrderTheSDKChecks() {
        let broken = page("a", banner: "ftp://x")
        #expect(rule(FeaturedComponent(items: [broken, page("a")])) == .urlScheme)
        #expect(rule(FeaturedComponent(items: [broken], autoAdvance: 1)) == .numberRange)
        #expect(rule(FeaturedComponent(items: [], autoAdvance: 1)) == .countFeatured)
        let manyChips = (0..<7).map { _ in FeaturedChip(kind: 0, text: "") }
        #expect(rule(FeaturedComponent(items: [page(chips: manyChips)])) == .countChips)
        var tagged = page(chips: [FeaturedChip(kind: 1, number: 1)])
        tagged.tagline = ""
        #expect(rule(FeaturedComponent(items: [tagged])) == .lengthText)
        tagged.tagline = nil
        tagged.accent = 0x100_0000
        #expect(rule(FeaturedComponent(items: [tagged])) == .numberRange)
    }

    @Test func aFeaturedEntryKeepsTheEntryRules() {
        let chapters = [Chapter(key: "a", kind: .images), Chapter(key: "a", kind: .images)]
        let item = FeaturedItem(entry: .manga(Manga(key: "m", title: "M", chapters: chapters)))
        #expect(rule(FeaturedComponent(items: [item])) == .duplicateKey)
        let orphaned = FeaturedItem(entry: .manga(Manga(key: "m", title: "M", chapters: nil, catalog: ChapterCatalog(scope: .visible))))
        #expect(rule(FeaturedComponent(items: [orphaned])) == .catalogWithoutChapters)
    }

    @Test func aViolationNamesItsRuleAndNeverTheValue() {
        let component = FeaturedComponent(items: [page(banner: "ftp://secret.example/path")])
        do { try CatalogValidation.featured(component); Issue.record("accepted") }
        catch let violation as CatalogContractViolation {
            #expect(violation.description == "url.scheme" && !"\(violation)".contains("secret"))
        } catch { Issue.record("\(error)") }
    }

    @Test func featuredEntriesAreTheEntriesAHomeShows() throws {
        let (_, featured) = try featuredComponent("home.featured.mixed_kinds")
        #expect(HomeComponentValue.featured(featured).entries.map(\.kind) == [.manga, .anime, .novel])
    }
}

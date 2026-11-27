import Foundation
import Testing
@testable import ito_runner

private let encoder = ItoPostcardEncoder(abiVersion: 3)

/// Where the guests below keep what they were called with.
private let featuresOffset = catalogCaptureOffset
private let legacyCallsOffset = catalogCaptureOffset + 16
private let v2CallsOffset = catalogCaptureOffset + 32

@Suite("Home export selection")
struct HomeExportTests {
    private static let v2Offset = 1_024
    private static let legacyOffset = 20_000
    private static let errorOffset = 40_000

    private let featuredHome = HomeLayout(components: [
        HomeComponent(title: "Spotlight", value: .featured(FeaturedComponent(
            items: [FeaturedItem(
                entry: .manga(Manga(key: "m", title: "M")),
                banner: "https://example.test/b.jpg",
                badge: FeaturedBadge(kind: 2, rank: 1),
                chips: [FeaturedChip(kind: 1, number: 2024)],
                action: 1)],
            autoAdvance: 8)))
    ])

    private let legacyHome = HomeLayout(components: [
        HomeComponent(title: "Legacy", value: .bigScroller([Manga(key: "m", title: "M")], nil))
    ])

    private func counted(_ offset: Int) -> String {
        "i32.const \(offset) i32.const \(offset) i32.load i32.const 1 i32.add i32.store"
    }

    /// `get_home` answers with `legacy`, counting its calls.
    private func legacyExport(_ legacy: HomeLayout) throws -> (String, [(offset: Int, bytes: [UInt8])]) {
        let bytes = try encoder.encode(legacy)
        return ("""
            (func (export "get_home") (result i64)
              \(counted(legacyCallsOffset))
              i64.const \(catalogPacked(Self.legacyOffset, bytes.count)))
            """, [(Self.legacyOffset, bytes)])
    }

    /// `get_home_v2` with `signature` answers with `layout`, counting its calls and keeping its
    /// first argument when it has one.
    private func v2Export(_ layout: HomeLayout, signature: String = "(param $features i32) (result i64)")
        throws -> (String, [(offset: Int, bytes: [UInt8])]) {
        let bytes = try encoder.encode(layout)
        let keep = signature.hasPrefix("(param $features i32)")
            ? "i32.const \(featuresOffset) local.get $features i32.store" : ""
        return ("""
            (func (export "get_home_v2") \(signature)
              \(counted(v2CallsOffset)) \(keep)
              i64.const \(catalogPacked(Self.v2Offset, bytes.count)))
            """, [(Self.v2Offset, bytes)])
    }

    /// `get_home_v2` fails: it reports `category` and `message` through `ito_last_error`, then returns 0.
    private func failingV2(_ category: PluginErrorCategory, _ message: String?)
        throws -> (String, [(offset: Int, bytes: [UInt8])]) {
        var exports = """
            (func (export "get_home_v2") (param i32) (result i64) \(counted(v2CallsOffset)) i64.const 0)
            """
        var buffers: [(offset: Int, bytes: [UInt8])] = []
        if let message {
            let payload = try encoder.encode(PluginErrorPayload(category: category, message: message))
            exports += """

                (func (export "ito_last_error") (result i64)
                  i64.const \(catalogPacked(Self.errorOffset, payload.count)))
                """
            buffers = [(Self.errorOffset, payload)]
        }
        return (exports, buffers)
    }

    private func runner(kinds: Int = 0b111, _ parts: (String, [(offset: Int, bytes: [UInt8])])...) async throws -> ItoRunner {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: catalogPlugin(
            exports: parts.map(\.0).joined(separator: "\n"), kinds: kinds, responses: parts.flatMap(\.1)))
        return runner
    }

    private func word(_ runner: ItoRunner, at offset: Int) async throws -> Int {
        try await runner.readMemory(offset: offset, length: 4).reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    private func titles(_ home: HomeLayout) -> [String?] { home.components.map(\.title) }

    // MARK: Selection

    @Test func aPluginWithoutTheNewExportIsCalledAsBefore() async throws {
        let plugin = try await runner(legacyExport(legacyHome))
        let home = try await plugin.getHome(context: .test)
        #expect(titles(home) == ["Legacy"])
        #expect(try await word(plugin, at: legacyCallsOffset) == 1)
    }

    @Test func theNewExportIsPreferredAndGetsTheFeaturesThisRunnerShows() async throws {
        let plugin = try await runner(legacyExport(legacyHome), v2Export(featuredHome))
        let home = try await plugin.getHome(context: .test)
        #expect(titles(home) == ["Spotlight"])
        guard case .featured(let featured) = home.components[0].value else { Issue.record("not featured"); return }
        #expect(featured.items.count == 1 && featured.items[0].banner == "https://example.test/b.jpg")
        #expect(featured.items[0].badge?.kind == 2 && featured.items[0].action == 1 && featured.autoAdvance == 8)
        #expect(try await word(plugin, at: featuresOffset) == Int(ItoRunner.supportedHomeFeatures.rawValue))
        #expect(try await word(plugin, at: v2CallsOffset) == 1)
        #expect(try await word(plugin, at: legacyCallsOffset) == 0, "the legacy export is not called")
    }

    @Test func aPluginWhoseNewExportReportsUnsupportedFallsBackToTheLegacyOne() async throws {
        let plugin = try await runner(legacyExport(legacyHome), failingV2(.unsupported, "Unsupported operation"))
        let home = try await plugin.getHome(context: .test)
        #expect(titles(home) == ["Legacy"])
        #expect(try await word(plugin, at: v2CallsOffset) == 1)
        #expect(try await word(plugin, at: legacyCallsOffset) == 1)
    }

    /// A refusal that merely says "Unsupported operation" is not the typed category.
    @Test(arguments: [PluginErrorCategory.other, .unauthorized, .needsSetup, .server])
    func anyOtherFailureIsReportedAndNeverRetriedOnTheLegacyExport(_ category: PluginErrorCategory) async throws {
        let plugin = try await runner(legacyExport(legacyHome), failingV2(category, "Unsupported operation"))
        await #expect(throws: ItoError.pluginFailed(function: "get_home_v2", reason: "Unsupported operation", category: category)) {
            try await plugin.getHome(context: .test)
        }
        #expect(try await word(plugin, at: legacyCallsOffset) == 0)
    }

    @Test func aFailureWithNoReportIsReportedToo() async throws {
        let plugin = try await runner(legacyExport(legacyHome), failingV2(.other, nil))
        await #expect(throws: ItoError.pluginFailed(function: "get_home_v2", reason: nil)) {
            try await plugin.getHome(context: .test)
        }
        #expect(try await word(plugin, at: legacyCallsOffset) == 0)
    }

    @Test func aViolationThePluginReportsIsNotRetriedOnTheLegacyExport() async throws {
        let plugin = try await runner(legacyExport(legacyHome), failingV2(.contractViolation, "count.featured"))
        await #expect(throws: ItoError.catalogContractViolation(
            function: "get_home_v2", violation: CatalogContractViolation(.countFeatured))) {
            try await plugin.getHome(context: .test)
        }
        #expect(try await word(plugin, at: legacyCallsOffset) == 0)
    }

    /// Only the exact `(i32) -> i64` is the export; anything else is the plugin's contract violation.
    @Test(arguments: [
        "(result i64)",
        "(param i64) (result i64)",
        "(param i32 i32) (result i64)",
        "(param i32) (result i32)",
        "(param f32) (result i64)"
    ])
    func aWrongSignatureIsAViolationAndIsNeverRetriedOnTheLegacyExport(_ signature: String) async throws {
        let bytes = try encoder.encode(featuredHome)
        let result = signature.hasSuffix("(result i32)") ? "i32.const 0" : "i64.const \(catalogPacked(Self.v2Offset, bytes.count))"
        let plugin = try await runner(legacyExport(legacyHome), (
            "(func (export \"get_home_v2\") \(signature) \(counted(v2CallsOffset)) \(result))", [(Self.v2Offset, bytes)]))
        await #expect(throws: ItoError.controlContractViolation(function: "get_home_v2", violation: .init(.signature)),
            Comment(rawValue: signature)) {
            try await plugin.getHome(context: .test)
        }
        #expect(try await word(plugin, at: v2CallsOffset) == 0, "a wrong signature is never called")
        #expect(try await word(plugin, at: legacyCallsOffset) == 0)
    }

    @Test func aGlobalOrTableNamedLikeTheExportIsNotTheExport() async throws {
        let plugin = try await runner(legacyExport(legacyHome), ("(global (export \"get_home_v2\") i32 (i32.const 1))", []))
        await #expect(throws: ItoError.controlContractViolation(function: "get_home_v2", violation: .init(.signature))) {
            try await plugin.getHome(context: .test)
        }
    }

    // MARK: What the new export returns is held to the same rules

    @Test func aFeaturedHomeThatBreaksARuleIsRefusedUnderTheExportThatReturnedIt() async throws {
        var broken = featuredHome
        guard case .featured(var featured) = broken.components[0].value else { return }
        featured.items[0].banner = "ftp://example.test/b.jpg"
        broken.components[0].value = .featured(featured)
        let plugin = try await runner(legacyExport(legacyHome), v2Export(broken))
        await #expect(throws: ItoError.catalogContractViolation(
            function: "get_home_v2", violation: CatalogContractViolation(.urlScheme))) {
            try await plugin.getHome(context: .test)
        }
        #expect(try await word(plugin, at: legacyCallsOffset) == 0)
    }

    @Test func aFeaturedEntryOfAKindThePluginDoesNotServeIsRefused() async throws {
        let home = HomeLayout(components: [HomeComponent(value: .featured(FeaturedComponent(
            items: [FeaturedItem(entry: .manga(Manga(key: "m", title: "M"))), FeaturedItem(entry: .anime(Anime(key: "a", title: "A")))])))])
        let plugin = try await runner(kinds: 0b001, v2Export(home))
        await #expect(throws: ItoError.pluginFailed(
            function: "get_home_v2", reason: "The plugin returned a kind it doesn't serve (anime).")) {
            try await plugin.getHome(context: .test)
        }
        // The same entries are served by a plugin that serves both kinds.
        let both = try await runner(kinds: 0b011, v2Export(home))
        #expect(try await both.getHome(context: .test).components.count == 1)
    }

    @Test func aNewExportThatReturnsAnUnknownVariantIsADecodingError() async throws {
        // One untitled component of variant 18, which no runner knows yet.
        let bytes: [UInt8] = [1, 0, 0, 18, 0]
        let plugin = try await runner(("""
            (func (export "get_home_v2") (param i32) (result i64) i64.const \(catalogPacked(Self.v2Offset, bytes.count)))
            """, [(Self.v2Offset, bytes)]), legacyExport(legacyHome))
        await #expect(throws: DecodingError.self) { try await plugin.getHome(context: .test) }
    }
}

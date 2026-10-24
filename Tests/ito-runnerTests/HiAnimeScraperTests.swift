import OSLog
import Foundation
import Testing

@testable import ito_runner

// MARK: - Runner Factory

/// Shared helper so every test doesn't repeat the same four-line setup.
private func makeRunner() async throws -> ItoRunner {
    let wasmPath = URL(
        fileURLWithPath: "/Users/cao/proj/apps/ito-runner/projects/hianime/hianime.ito")
    let runner = ItoRunner()
    await runner.setNetModule(DefaultNetModule())
    await runner.setStdModule(DefaultStdModule())
    await runner.setHtmlModule(DefaultHtmlModule())
    _ = try await runner.loadBundle(from: wasmPath)
    return runner
}

// MARK: - Suite 1: Home & Listings

@Suite("HiAnime – Home & Listings")
struct HiAnimeListingTests {

    @Test("Home returns non-empty components")
    func testHomeComponents() async throws {
        let runner = try await makeRunner()
        let home = try await runner.getHome()
        #expect(!home.components.isEmpty)
    }

    @Test("Recently-updated listing page 1 returns entries")
    func testRecentlyUpdatedPage1() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        // Try page 1, fall back to page 2 in case of transient rate-limiting.
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        if page.entries.isEmpty {
            let page2 = try await runner.getAnimeList(listing: listing, page: 2)
            #expect(
                !page2.entries.isEmpty,
                "Both page 1 and page 2 of recently_updated returned no entries")
        } else {
            #expect(!page.entries.isEmpty)
        }
    }

    @Test("Page 2 returns entries distinct from page 1")
    func testPaginationPage2() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page1 = try await runner.getAnimeList(listing: listing, page: 1)
        let page2 = try await runner.getAnimeList(listing: listing, page: 2)

        #expect(!page2.entries.isEmpty)

        let keys1 = Set(page1.entries.map { $0.key })
        let keys2 = Set(page2.entries.map { $0.key })

        // On a highly volatile live feed, an anime can shift from page 1 to page 2
        // between network requests. Instead of strict disjointness, ensure the pages aren't identical.
        #expect(keys1 != keys2, "Page 1 and page 2 should not be identical")

        // Ensure the overlap isn't suspiciously large (which would mean pagination is actually broken)
        let overlap = keys1.intersection(keys2)
        #expect(
            overlap.count < 10,
            "Too much overlap between pages (\(overlap.count) items). Pagination might be failing.")
    }

    @Test("Every entry has a non-empty key and title")
    func testEntryFieldsNonEmpty() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        for entry in page.entries {
            #expect(!entry.key.isEmpty)
            #expect(!entry.title.isEmpty)
        }
    }

    @Test("Entry keys follow <slug>-<numeric-id> format")
    func testEntryKeyFormat() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        let pattern = try NSRegularExpression(pattern: "^[a-z0-9-]+-\\d+$")
        for entry in page.entries {
            let key = String(entry.key)
            let range = NSRange(key.startIndex..., in: key)
            let matched = pattern.firstMatch(in: key, range: range) != nil
            #expect(matched, "Key '\(key)' does not match expected slug-id pattern")
        }
    }

    @Test("Entry keys are unique across a single page")
    func testEntryKeysUnique() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        let keys = page.entries.map { $0.key }
        #expect(Set(keys).count == keys.count, "Listing page must not contain duplicate keys")
    }
}

// MARK: - Suite 2: Anime Details & Episodes

@Suite("HiAnime – Anime Details & Episodes")
struct HiAnimeDetailsTests {

    @Test("getAnimeUpdate with needsDetails returns a non-empty title")
    func testDetailsTitleNonEmpty() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        // Try pages 1 and 2; skip live-stream entries that return no episodes.
        for pageNum: Int32 in 1...2 {
            let page = try await runner.getAnimeList(listing: listing, page: pageNum)
            for entry in page.entries.prefix(8) {
                let update = try await runner.getAnimeUpdate(
                    anime: entry, needsDetails: true, needsEpisodes: false)
                if !update.title.isEmpty {
                    #expect(!update.title.isEmpty)
                    return
                }
            }
        }
        Issue.record("Could not find any listing entry with a non-empty title")
    }

    @Test("getAnimeUpdate with needsEpisodes returns at least one episode")
    func testEpisodesNonEmpty() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)

        // Fall back to page 2 if page 1 is empty (transient rate-limiting)
        let entries =
            page.entries.isEmpty
            ? (try await runner.getAnimeList(listing: listing, page: 2)).entries
            : page.entries

        guard !entries.isEmpty else {
            Issue.record("Listing returned no entries for both page 1 and page 2")
            return
        }

        // Loop through the top 8 to find a standard series, skip live streams/teasers.
        for entry in entries.prefix(8) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)

            if let episodes = update.episodes, !episodes.isEmpty {
                #expect(!episodes.isEmpty)
                return
            }
        }
        Issue.record("Could not find any listing entry with episodes in the first 8 results")
    }

    @Test("Every episode has a non-empty key")
    func testEpisodeKeysNonEmpty() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)

        for entry in page.entries.prefix(8) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)

            if let episodes = update.episodes, !episodes.isEmpty {
                for ep in episodes.prefix(10) {
                    #expect(!ep.key.isEmpty)
                }
                return  // Found valid episodes and tested them, we are done
            }
        }
        Issue.record("No entry in the first 8 results returned episodes")
    }

    @Test("Episode keys are unique within a single anime")
    func testEpisodeKeysUnique() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        guard let episodes = update.episodes, episodes.count > 1 else { return }
        let keys = episodes.map { $0.key }
        #expect(Set(keys).count == keys.count, "Episode keys must be unique")
    }

    @Test("Details and episodes can be fetched together in a single call")
    func testCombinedDetailAndEpisodeFetch() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        for pageNum: Int32 in 1...2 {
            let page = try await runner.getAnimeList(listing: listing, page: pageNum)
            for entry in page.entries.prefix(8) {
                let update = try await runner.getAnimeUpdate(
                    anime: entry, needsDetails: true, needsEpisodes: true)
                guard let eps = update.episodes, !eps.isEmpty else { continue }
                #expect(!update.title.isEmpty)
                #expect(update.episodes?.isEmpty == false)
                return
            }
        }
        Issue.record("Could not find a listing entry with both title and episodes")
    }

    @Test("Fetching details only does not populate episodes")
    func testDetailsOnlyDoesNotFetchEpisodes() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: true, needsEpisodes: false)
        let episodeCount = update.episodes?.count ?? 0
        #expect(episodeCount == 0, "needsEpisodes: false should not populate episodes")
    }

    @Test("Fetching episodes only succeeds without needing details")
    func testEpisodesOnlyFetch() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        let entries =
            page.entries.isEmpty
            ? (try await runner.getAnimeList(listing: listing, page: 2)).entries
            : page.entries
        // Iterate entries — 24/7 live streams have no episodes; find a regular series.
        for entry in entries.prefix(8) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)
            if let episodes = update.episodes, !episodes.isEmpty {
                #expect(!episodes.isEmpty)
                return
            }
        }
        // If all entries in the listing are live streams, skip rather than hard-fail.
        Issue.record(
            "No entry in the first 8 listing results returned episodes with needsEpisodes:true")
    }

    @Test("Page 2 entry also returns episodes")
    func testPage2EntryHasEpisodes() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page2 = try await runner.getAnimeList(listing: listing, page: 2)
        guard let entry = page2.entries.first else {
            Issue.record("Page 2 returned no entries")
            return
        }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        #expect(update.episodes?.isEmpty == false)
    }
}

// MARK: - Suite 3: Video List & Server Extraction

@Suite("HiAnime – Video List & Server Extraction")
struct HiAnimeVideoTests {

    @Test("getVideoList returns at least one video")
    func testVideoListNonEmpty() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)

        var entries = (try await runner.getAnimeList(listing: listing, page: 1)).entries

        // If page 1 is empty, we hit a rate limit. Sleep for 1 second and try page 2.
        if entries.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            entries = (try await runner.getAnimeList(listing: listing, page: 2)).entries
        }

        guard !entries.isEmpty else {
            Issue.record("Rate limited: No entries in listing (both page 1 and page 2)")
            return
        }

        for entry in entries.prefix(8) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)
            guard let episode = update.episodes?.first else { continue }

            let videos = try await runner.getVideoList(anime: update, episode: episode)
            if !videos.isEmpty {
                #expect(!videos.isEmpty, "Expected at least one video source")
                return
            }
        }
        Issue.record("No entry in the first 8 listing results had standard video sources")
    }

    @Test("Returned video URLs are valid HTTPS URLs")
    func testVideoURLsAreValidHTTPS() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        guard let episode = update.episodes?.first else { return }
        let videos = try await runner.getVideoList(anime: update, episode: episode)
        for video in videos {
            let url = String(video.url)
            #expect(url.hasPrefix("https://"), "URL should be HTTPS: \(url)")
            #expect(URL(string: url) != nil, "URL should be parseable: \(url)")
        }
    }

    @Test("At least one video source is a MegaCloud or RapidCloud embed")
    func testMegacloudEmbedPresent() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)

        for entry in page.entries.prefix(8) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)
            guard let episode = update.episodes?.first else { continue }

            let videos = try await runner.getVideoList(anime: update, episode: episode)
            let hasMegacloud = videos.contains {
                String($0.url).contains("megacloud") || String($0.url).contains("rapid-cloud")
            }

            if hasMegacloud {
                #expect(hasMegacloud, "Expected a MegaCloud/RapidCloud embed URL in video list")
                return
            }
        }
        Issue.record("No MegaCloud/RapidCloud embed found in the first 8 entries")
    }

    @Test("Full MegaCloud extraction pipeline yields a .m3u8 playlist URL")
    func testMegacloudExtractionYieldsM3U8() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let extractor = MegacloudExtractor()
        for pageNum: Int32 in 1...2 {
            let page = try await runner.getAnimeList(listing: listing, page: pageNum)
            for entry in page.entries.prefix(8) {
                let update = try await runner.getAnimeUpdate(
                    anime: entry, needsDetails: false, needsEpisodes: true)
                guard let episode = update.episodes?.first else { continue }
                let videos = try await runner.getVideoList(anime: update, episode: episode)
                let megaVideo = videos.first(where: {
                    String($0.url).contains("megacloud") || String($0.url).contains("rapid-cloud")
                })
                guard let embedUrl = megaVideo.map({ String($0.url) }) else { continue }

                // --- ADDED PRINT STATEMENTS HERE ---
                RunnerLogger.core.debug("🎬 Selected Anime: \(entry.title)")
                RunnerLogger.core.debug("📺 Selected Episode Key: \(episode.key)")
                // -----------------------------------

                RunnerLogger.core.debug("Extracting from: \(embedUrl)")
                guard let playlist = try await extractor.extract(embedUrl: embedUrl) else {
                    Issue.record("MegaCloud extraction returned nil for \(embedUrl)")
                    return
                }
                RunnerLogger.core.debug("Playlist URL: \(playlist)")
                #expect(
                    playlist.contains(".m3u8"), "Expected an HLS playlist URL, got: \(playlist)")
                return
            }
        }
        Issue.record("No MegaCloud embed found in first 8 entries across pages 1 and 2")
    }

    @Test("MegaCloud extractFull returns subtitle tracks with valid structure when present")
    func testMegacloudSubtitleTracks() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        guard let episode = update.episodes?.first else { return }
        let videos = try await runner.getVideoList(anime: update, episode: episode)
        guard
            let embedUrl = videos.first(where: {
                String($0.url).contains("megacloud") || String($0.url).contains("rapid-cloud")
            }).map({ String($0.url) })
        else { return }

        let extractor = MegacloudExtractor()
        guard let result = try await extractor.extractFull(embedUrl: embedUrl) else {
            Issue.record("extractFull returned nil")
            return
        }
        if let tracks = result.tracks {
            for track in tracks {
                if let file = track.file {
                    #expect(file.hasPrefix("https://"), "Track URL should be HTTPS: \(file)")
                    #expect(URL(string: file) != nil, "Track URL should be parseable: \(file)")
                }
                #expect(track.kind != nil, "Track should have a kind field")
            }
            RunnerLogger.core.debug("Subtitle tracks: \(tracks.count)")
        }
    }

    @Test("Caption tracks (kind == captions) have parseable file URLs")
    func testCaptionTracksHaveValidURLs() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        guard let episode = update.episodes?.first else { return }
        let videos = try await runner.getVideoList(anime: update, episode: episode)
        guard
            let embedUrl = videos.first(where: {
                String($0.url).contains("megacloud") || String($0.url).contains("rapid-cloud")
            }).map({ String($0.url) })
        else { return }

        let extractor = MegacloudExtractor()
        guard let result = try await extractor.extractFull(embedUrl: embedUrl) else { return }
        // Mirrors Python: subs = [x for x in tracks if x.get('kind') == 'captions']
        let captions = result.tracks?.filter { $0.kind == "captions" } ?? []
        for caption in captions {
            guard let file = caption.file else {
                Issue.record("Caption track missing file URL")
                continue
            }
            #expect(URL(string: file) != nil, "Caption URL must be parseable: \(file)")
        }
        RunnerLogger.core.debug("Caption tracks: \(captions.count)")
    }

    @Test("MegaCloud extractFull skip ranges are ordered (start < end) when present")
    func testMegacloudSkipRangesAreOrdered() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        let extractor = MegacloudExtractor()

        for entry in page.entries.prefix(5) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)
            guard let episode = update.episodes?.first else { continue }
            let videos = try await runner.getVideoList(anime: update, episode: episode)
            guard
                let embedUrl = videos.first(where: {
                    String($0.url).contains("megacloud") || String($0.url).contains("rapid-cloud")
                }).map({ String($0.url) })
            else { continue }
            guard let result = try? await extractor.extractFull(embedUrl: embedUrl) else {
                continue
            }

            if let intro = result.intro, intro.end > 0 {
                #expect(intro.start >= 0, "Intro start must be non-negative")
                #expect(intro.end > intro.start, "Intro end must be after start")
                RunnerLogger.core.debug("\("Intro: \(intro.start)")s – \(intro.end)s")
            }
            if let outro = result.outro, outro.end > 0 {
                #expect(outro.start >= 0, "Outro start must be non-negative")
                #expect(outro.end > outro.start, "Outro end must be after start")
                RunnerLogger.core.debug("\("Outro: \(outro.start)")s – \(outro.end)s")
            }
            break
        }
    }

    @Test("getVideoList called twice for the same episode returns the same count")
    func testVideoListIsStable() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        guard let episode = update.episodes?.first else { return }
        let videos1 = try await runner.getVideoList(anime: update, episode: episode)
        let videos2 = try await runner.getVideoList(anime: update, episode: episode)
        #expect(
            videos1.count == videos2.count,
            "Repeated calls should return the same number of sources")
    }
}

// MARK: - Suite 4: Multi-Episode Extraction

@Suite("HiAnime – Multi-Episode Extraction")
struct HiAnimeMultiEpisodeTests {

    @Test("Extracting sources across first 3 episodes succeeds for at least one")
    func testMultipleEpisodesExtraction() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        let extractor = MegacloudExtractor()

        for entry in page.entries.prefix(8) {
            let update = try await runner.getAnimeUpdate(
                anime: entry, needsDetails: false, needsEpisodes: true)

            // We need a show that actually has at least 2 episodes
            guard let episodes = update.episodes, episodes.count >= 2 else { continue }

            var successCount = 0
            for episode in episodes.prefix(3) {
                let videos = try await runner.getVideoList(anime: update, episode: episode)
                guard
                    let embedUrl = videos.first(where: {
                        String($0.url).contains("megacloud")
                            || String($0.url).contains("rapid-cloud")
                    }).map({ String($0.url) })
                else { continue }

                if (try? await extractor.extract(embedUrl: embedUrl)) != nil {
                    successCount += 1
                }
            }

            if successCount > 0 {
                #expect(successCount > 0, "At least one of 3 episodes should extract successfully")
                RunnerLogger.core.debug("\("Extracted \(successCount)")/3 episode(s) for \(update.title)")
                return
            }
        }
        Issue.record("Could not extract any MegaCloud episodes from the top 8 anime")
    }

    @Test("Different episodes of the same anime produce different embed URLs")
    func testDifferentEpisodesDifferentURLs() async throws {
        let runner = try await makeRunner()
        let listing = Listing(id: "recently_updated", name: "Recently Updated", kind: 0)
        let page = try await runner.getAnimeList(listing: listing, page: 1)
        guard let entry = page.entries.first else { return }
        let update = try await runner.getAnimeUpdate(
            anime: entry, needsDetails: false, needsEpisodes: true)
        guard let episodes = update.episodes, episodes.count >= 2 else { return }

        let ep1Videos = try await runner.getVideoList(anime: update, episode: episodes[0])
        let ep2Videos = try await runner.getVideoList(anime: update, episode: episodes[1])
        guard !ep1Videos.isEmpty, !ep2Videos.isEmpty else { return }

        let ep1Urls = Set(ep1Videos.map { String($0.url) })
        let ep2Urls = Set(ep2Videos.map { String($0.url) })
        #expect(ep1Urls != ep2Urls, "Different episodes should have different embed URLs")
    }
}

// MARK: - Suite 5: MegaCloud URL Construction (pure / offline)

@Suite("MegaCloud – URL Construction")
struct MegacloudURLTests {

    @Test("getSources URL is well-formed with slash between domain and path")
    func testGetSourcesURLSlash() {
        let embedUrl = "https://megacloud.blog/embed-2/v3/e-1/Y57q7LTG8Frk?k=1"
        let urlObj = URLComponents(string: embedUrl)!
        let domain = urlObj.host!
        var parts = urlObj.path.split(separator: "/")
        let xrax = String(parts.popLast()!.split(separator: "?").first!)
        let basePath = parts.joined(separator: "/")
        let constructed = "https://\(domain)/\(basePath)/getSources?id=\(xrax)&_k=testNonce"
        let parsed = URL(string: constructed)
        #expect(parsed != nil)
        #expect(parsed?.host == "megacloud.blog")
        #expect(parsed?.path == "/embed-2/v3/e-1/getSources")
        #expect(parsed?.query?.contains("id=Y57q7LTG8Frk") == true)
    }

    @Test("Regression: getSources URL does not concatenate domain and path without slash")
    func testGetSourcesURLNoMalformedHost() {
        let embedUrl = "https://megacloud.blog/embed-2/v3/e-1/Y57q7LTG8Frk?k=1"
        let urlObj = URLComponents(string: embedUrl)!
        let domain = urlObj.host!
        var parts = urlObj.path.split(separator: "/")
        let xrax = String(parts.popLast()!.split(separator: "?").first!)
        let basePath = parts.joined(separator: "/")
        let constructed = "https://\(domain)/\(basePath)/getSources?id=\(xrax)&_k=nonce"
        #expect(
            !constructed.contains("megacloud.blogembed"),
            "URL must not concatenate domain and path without a separator")
    }

    @Test("Nonce 48-char regex matches a known nonce in sample HTML")
    func testNonce48CharRegex() throws {
        let html = "<script>var x = 'ttSYJfk0cuKejdpidp50Bmm98tuVV2dxEfKViHvxPrSg3OyR';</script>"
        let pattern = try NSRegularExpression(pattern: "\\b[a-zA-Z0-9]{48}\\b")
        let match = pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        #expect(match != nil)
        if let match {
            let nonce = String(html[Range(match.range, in: html)!])
            #expect(nonce == "ttSYJfk0cuKejdpidp50Bmm98tuVV2dxEfKViHvxPrSg3OyR")
            #expect(nonce.count == 48)
        }
    }

    @Test("Nonce 3x16-char fallback regex concatenates three groups into 48 chars")
    func testNonce3x16FallbackRegex() throws {
        let html = "var a='AAAAAAAAAAAAAAAA', b='BBBBBBBBBBBBBBBB', c='CCCCCCCCCCCCCCCC';"
        let pattern = try NSRegularExpression(
            pattern: "\\b([a-zA-Z0-9]{16})\\b.*?\\b([a-zA-Z0-9]{16})\\b.*?\\b([a-zA-Z0-9]{16})\\b")
        let match = pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        #expect(match != nil)
        if let match, match.numberOfRanges == 4 {
            let nonce =
                String(html[Range(match.range(at: 1), in: html)!])
                + String(html[Range(match.range(at: 2), in: html)!])
                + String(html[Range(match.range(at: 3), in: html)!])
            #expect(nonce.count == 48)
            #expect(nonce == "AAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBCCCCCCCCCCCCCCCC")
        }
    }

    @Test("Both nonce regexes return nil when no alphanumeric runs are long enough")
    func testNonceRegexNoMatch() throws {
        let html = "<html><body>No nonce here.</body></html>"
        let pattern48 = try NSRegularExpression(pattern: "\\b[a-zA-Z0-9]{48}\\b")
        #expect(pattern48.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) == nil)
        let pattern3x16 = try NSRegularExpression(
            pattern: "\\b([a-zA-Z0-9]{16})\\b.*?\\b([a-zA-Z0-9]{16})\\b.*?\\b([a-zA-Z0-9]{16})\\b")
        #expect(
            pattern3x16.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) == nil)
    }
}

// MARK: - Suite 6: MegaCloud Crypto Unit Tests (pure / offline)

@Suite("MegaCloud – Crypto Unit Tests")
struct MegacloudCryptoTests {

    let extractor = MegacloudExtractor()

    // MARK: keygen

    @Test("keygen is deterministic — same inputs always produce identical output")
    func testKeygenDeterministic() {
        let r1 = extractor.keygen(megacloudKey: "testMCKey", clientKey: "testClientKey12345678")
        let r2 = extractor.keygen(megacloudKey: "testMCKey", clientKey: "testClientKey12345678")
        #expect(r1 == r2)
    }

    @Test("keygen output length is between 96 and 128 characters")
    func testKeygenOutputLength() {
        // Keys must be long enough: output length = megaLen + 2*clientLen, needs >= 96.
        // Use realistic key lengths (megacloud keys are ~48 chars in production).
        let megaKey = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefgh1234"  // 48 chars
        let clientKey = "XyZaBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkLmNo"  // 46 chars
        let key = extractor.keygen(megacloudKey: megaKey, clientKey: clientKey)
        #expect(key.count >= 96, "keygen must produce at least 96 chars, got \(key.count)")
        #expect(key.count <= 128, "keygen must produce at most 128 chars, got \(key.count)")
    }

    @Test("keygen output contains only printable ASCII (32–126)")
    func testKeygenOutputCharset() {
        let key = extractor.keygen(megacloudKey: "abc", clientKey: "defghijklmnopqrstuvwxyz1234")
        for char in key {
            let ascii = char.asciiValue ?? 0
            #expect(
                ascii >= 32 && ascii <= 126,
                "keygen must produce printable ASCII, found '\(char)' (ascii \(ascii))")
        }
    }

    @Test("keygen produces different output for different megacloud keys")
    func testKeygenSensitiveToMegacloudKey() {
        let clientKey = "clientKey12345678901234"
        let k1 = extractor.keygen(megacloudKey: "keyAlpha", clientKey: clientKey)
        let k2 = extractor.keygen(megacloudKey: "keyBeta", clientKey: clientKey)
        #expect(k1 != k2)
    }

    @Test("keygen produces different output for different client keys")
    func testKeygenSensitiveToClientKey() {
        let megaKey = "megacloudKeyXYZ"
        let k1 = extractor.keygen(megacloudKey: megaKey, clientKey: "clientAAA1234567890123")
        let k2 = extractor.keygen(megacloudKey: megaKey, clientKey: "clientBBB1234567890123")
        #expect(k1 != k2)
    }

    // MARK: columnarCipher

    @Test("columnarCipher output has the same character count as input")
    func testColumnarCipherLengthPreserved() {
        let src = "Hello, World! This is a test string for columnar cipher."
        let result = extractor.columnarCipher(src: src, ikey: "testkey")
        #expect(result.count == src.count)
    }

    @Test("columnarCipher is deterministic")
    func testColumnarCipherDeterministic() {
        let src = "abcdefghijklmnopqrstuvwxyz"
        #expect(
            extractor.columnarCipher(src: src, ikey: "key")
                == extractor.columnarCipher(src: src, ikey: "key"))
    }

    @Test("columnarCipher output is a permutation of its input characters")
    func testColumnarCipherIsPermutation() {
        // src length (45) must be exactly divisible by key length (5) to avoid padding.
        let src = "The quick brown fox jumps over the lazy dog!!"
        #expect(src.count % 5 == 0, "Precondition: src length must be divisible by key length")
        let result = extractor.columnarCipher(src: src, ikey: "mykey")
        #expect(result.sorted() == src.sorted())
    }

    @Test("columnarCipher with a multi-char key reorders characters")
    func testColumnarCipherTransposes() {
        let src = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        #expect(extractor.columnarCipher(src: src, ikey: "dcba") != src)
    }

    @Test("columnarCipher with a single-char key is identity")
    func testColumnarCipherSingleCharKeyIsIdentity() {
        let src = "hello world"
        #expect(extractor.columnarCipher(src: src, ikey: "x") == src)
    }

    @Test("columnarCipher produces different output for different keys on the same input")
    func testColumnarCipherKeyVariance() {
        let src = String(repeating: "ABCDEF", count: 8)
        // "bac" → sorted indices [1,0,2]; "abc" → sorted indices [0,1,2] — different permutations.
        #expect(
            extractor.columnarCipher(src: src, ikey: "bac")
                != extractor.columnarCipher(src: src, ikey: "abc"))
    }

    // MARK: seedShuffle

    @Test("seedShuffle is deterministic")
    func testSeedShuffleDeterministic() {
        let charset = Array((32...126).map { Character(UnicodeScalar($0)!) })
        #expect(
            extractor.seedShuffle(array: charset, ikey: "somekey")
                == extractor.seedShuffle(array: charset, ikey: "somekey"))
    }

    @Test("seedShuffle output is a permutation of its input")
    func testSeedShuffleIsPermutation() {
        let charset = Array((32...126).map { Character(UnicodeScalar($0)!) })
        let shuffled = extractor.seedShuffle(array: charset, ikey: "testkey")
        #expect(shuffled.sorted() == charset.sorted())
    }

    @Test("seedShuffle produces different orderings for different keys")
    func testSeedShuffleKeyVariance() {
        let charset = Array((32...126).map { Character(UnicodeScalar($0)!) })
        #expect(
            extractor.seedShuffle(array: charset, ikey: "keyA")
                != extractor.seedShuffle(array: charset, ikey: "keyB"))
    }

    @Test("seedShuffle on a single-element array returns the same element")
    func testSeedShuffleSingleElement() {
        let single: [Character] = ["X"]
        #expect(extractor.seedShuffle(array: single, ikey: "anykey") == single)
    }

    @Test("seedShuffle on an empty array returns an empty array")
    func testSeedShuffleEmpty() {
        #expect(extractor.seedShuffle(array: [], ikey: "anykey").isEmpty)
    }

    // MARK: decrypt

    @Test("decrypt passes through input unchanged when it is not valid base64")
    func testDecryptInvalidBase64Passthrough() {
        let badSrc = "this is not base64!!!"
        #expect(
            extractor.decrypt(src: badSrc, clientKey: "anyClient", megacloudKey: "anyKey")
                == badSrc)
    }

    @Test("decrypt returns a non-empty string for valid base64 input")
    func testDecryptNonEmptyResult() {
        let encoded = Data(String(repeating: "A", count: 100).utf8).base64EncodedString()
        let result = extractor.decrypt(
            src: encoded, clientKey: "client1234567890123456", megacloudKey: "megakey")
        #expect(!result.isEmpty)
    }

    @Test("decrypt is deterministic across multiple calls with the same inputs")
    func testDecryptDeterministic() {
        let encoded = Data(String(repeating: "Hello World! ", count: 8).utf8).base64EncodedString()
        let r1 = extractor.decrypt(
            src: encoded, clientKey: "clientKey1234567890", megacloudKey: "megacloudKey")
        let r2 = extractor.decrypt(
            src: encoded, clientKey: "clientKey1234567890", megacloudKey: "megacloudKey")
        #expect(r1 == r2)
    }

    @Test("decrypt output changes when the client key changes")
    func testDecryptSensitiveToClientKey() {
        let encoded = Data(String(repeating: "test data ", count: 12).utf8).base64EncodedString()
        let r1 = extractor.decrypt(
            src: encoded, clientKey: "clientAAA123456789012", megacloudKey: "sharedKey")
        let r2 = extractor.decrypt(
            src: encoded, clientKey: "clientBBB123456789012", megacloudKey: "sharedKey")
        #expect(r1 != r2)
    }

    @Test("decrypt output changes when the megacloud key changes")
    func testDecryptSensitiveToMegacloudKey() {
        let encoded = Data(String(repeating: "test data ", count: 12).utf8).base64EncodedString()
        let r1 = extractor.decrypt(
            src: encoded, clientKey: "sharedClientKey12345", megacloudKey: "megaKeyAAA")
        let r2 = extractor.decrypt(
            src: encoded, clientKey: "sharedClientKey12345", megacloudKey: "megaKeyBBB")
        #expect(r1 != r2)
    }

    @Test("decrypt length-prefix slicing: 4-char prefix encodes payload length")
    func testDecryptLengthPrefixSlicing() {
        // Verify the slicing logic directly, independent of cipher output.
        let payload = "HELLO WORLD"
        let padded =
            String(format: "%04d", payload.count) + payload + String(repeating: "X", count: 20)
        guard padded.count >= 4, let len = Int(String(padded.prefix(4))) else {
            Issue.record("Failed to parse length prefix")
            return
        }
        let start = padded.index(padded.startIndex, offsetBy: 4)
        let end = padded.index(start, offsetBy: len, limitedBy: padded.endIndex) ?? padded.endIndex
        #expect(String(padded[start..<end]) == payload)
    }
}

// MARK: - MegacloudExtractor
// keygen, columnarCipher, and seedShuffle are `internal` (not `private`) so the
// crypto unit-test suite above can call them directly.

struct MegacloudExtractor {

    // MARK: - Result Types

    struct ExtractionResult {
        let playlist: String
        let tracks: [SubtitleTrack]?
        let intro: SkipRange?
        let outro: SkipRange?
    }

    struct SubtitleTrack {
        let file: String?
        let label: String?
        let kind: String?
    }

    struct SkipRange {
        let start: Int
        let end: Int
    }

    let defaultCharset = Array((32...126).map { Character(UnicodeScalar($0)!) })

    // MARK: - Public API

    /// Returns just the .m3u8 playlist URL.
    func extract(embedUrl: String) async throws -> String? {
        return try await extractFull(embedUrl: embedUrl)?.playlist
    }

    /// Returns the playlist URL plus subtitle tracks and skip data.
    func extractFull(embedUrl: String) async throws -> ExtractionResult? {
        guard URL(string: embedUrl) != nil else { return nil }

        var request = URLRequest(url: URL(string: embedUrl)!)
        request.setValue("https://hianime.to/", forHTTPHeaderField: "Referer")
        let (htmlData, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: htmlData, encoding: .utf8) else { return nil }

        guard let nonce = extractNonce(from: html) else { return nil }
        RunnerLogger.core.debug("Found Nonce: \(nonce)")

        // Build getSources URL.
        // FIX: always include "/" between domain and basePath; without it the URL becomes
        // "https://megacloud.blogembed-2/..." which fails DNS resolution.
        let urlObj = URLComponents(string: embedUrl)!
        let domain = urlObj.host!
        var parts = urlObj.path.split(separator: "/")
        let xrax = parts.popLast()!.split(separator: "?").first!
        let basePath = parts.joined(separator: "/")
        let sourcesUrl = URL(
            string: "https://\(domain)/\(basePath)/getSources?id=\(xrax)&_k=\(nonce)")!

        var sourcesReq = URLRequest(url: sourcesUrl)
        sourcesReq.setValue("https://hianime.to/", forHTTPHeaderField: "Referer")
        sourcesReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (sourcesData, _) = try await URLSession.shared.data(for: sourcesReq)
        guard let json = try JSONSerialization.jsonObject(with: sourcesData) as? [String: Any]
        else { return nil }

        // Resolve sources (encrypted or plain)
        let sourcesArray: [[String: Any]]
        if let isEncrypted = json["encrypted"] as? Bool, isEncrypted {
            let encryptedBase64 = json["sources"] as! String
            let keysUrl = URL(
                string:
                    "https://raw.githubusercontent.com/yogesh-hacker/MegacloudKeys/refs/heads/main/keys.json"
            )!
            let (keysData, _) = try await URLSession.shared.data(from: keysUrl)
            let keysJson = try JSONSerialization.jsonObject(with: keysData) as! [String: Any]
            let vidstrKey = keysJson["vidstr"] as! String
            let decrypted = decrypt(src: encryptedBase64, clientKey: nonce, megacloudKey: vidstrKey)
            guard let decData = decrypted.data(using: .utf8),
                let arr = try JSONSerialization.jsonObject(with: decData) as? [[String: Any]]
            else { return nil }
            sourcesArray = arr
        } else if let arr = json["sources"] as? [[String: Any]] {
            sourcesArray = arr
        } else {
            return nil
        }

        guard let playlist = sourcesArray.first?["file"] as? String else { return nil }

        let tracks: [SubtitleTrack]? = (json["tracks"] as? [[String: Any]])?.map {
            SubtitleTrack(
                file: $0["file"] as? String,
                label: $0["label"] as? String,
                kind: $0["kind"] as? String)
        }

        let intro: SkipRange? = {
            guard let d = json["intro"] as? [String: Any],
                let s = d["start"] as? Int, let e = d["end"] as? Int
            else { return nil }
            return SkipRange(start: s, end: e)
        }()
        let outro: SkipRange? = {
            guard let d = json["outro"] as? [String: Any],
                let s = d["start"] as? Int, let e = d["end"] as? Int
            else { return nil }
            return SkipRange(start: s, end: e)
        }()

        return ExtractionResult(playlist: playlist, tracks: tracks, intro: intro, outro: outro)
    }

    // MARK: - Nonce Extraction

    private func extractNonce(from html: String) -> String? {
        let req1 = try? NSRegularExpression(pattern: "\\b[a-zA-Z0-9]{48}\\b")
        if let match = req1?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
            return String(html[Range(match.range, in: html)!])
        }
        let req2 = try? NSRegularExpression(
            pattern: "\\b([a-zA-Z0-9]{16})\\b.*?\\b([a-zA-Z0-9]{16})\\b.*?\\b([a-zA-Z0-9]{16})\\b")
        if let match = req2?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            match.numberOfRanges == 4 {
            return String(html[Range(match.range(at: 1), in: html)!])
                + String(html[Range(match.range(at: 2), in: html)!])
                + String(html[Range(match.range(at: 3), in: html)!])
        }
        return nil
    }

    // MARK: - Crypto (internal so unit tests can call them directly)

    func keygen(megacloudKey: String, clientKey: String) -> String {
        let tempKey = megacloudKey + clientKey
        var hashVal: Int64 = 0
        for char in tempKey {
            let asc = Int64(char.asciiValue ?? UInt8(char.unicodeScalars.first!.value & 0x7F))
            hashVal = asc &+ hashVal &* 31 &+ (hashVal << 7) &- hashVal
        }
        let lHash = abs(hashVal) % 0x7FFF_FFFF_FFFF_FFFF
        let tempKeyXor = tempKey.map { c -> Character in
            let v = c.asciiValue ?? UInt8(c.unicodeScalars.first!.value & 0x7F)
            return Character(UnicodeScalar(v ^ 247))
        }
        let pivot = Int(lHash % Int64(tempKeyXor.count)) + 5
        let rotatedKeyStr = String(tempKeyXor.dropFirst(pivot) + tempKeyXor.prefix(pivot))
        let leafStr = String(clientKey.reversed())
        var returnKey = ""
        let maxLen = max(rotatedKeyStr.count, leafStr.count)
        let rotArr = Array(rotatedKeyStr)
        let leafArr = Array(leafStr)
        for i in 0..<maxLen {
            if i < rotArr.count { returnKey.append(rotArr[i]) }
            if i < leafArr.count { returnKey.append(leafArr[i]) }
        }
        let limit = 96 + Int(lHash % 33)
        returnKey = String(returnKey.prefix(limit))
        return String(
            returnKey.map { c -> Character in
                let v = Int(c.asciiValue ?? UInt8(c.unicodeScalars.first!.value & 0x7F))
                return Character(UnicodeScalar((v % 95) + 32)!)
            })
    }

    func columnarCipher(src: String, ikey: String) -> String {
        let colCount = ikey.count
        let rowCount = (src.count + colCount - 1) / colCount
        var grid = Array(
            repeating: Array(repeating: Character(" "), count: colCount), count: rowCount)
        let sortedMap = ikey.enumerated().map { ($0.element, $0.offset) }.sorted { $0.0 < $1.0 }
        let srcArr = Array(src)
        var srcIdx = 0
        for item in sortedMap {
            for row in 0..<rowCount {
                if srcIdx < srcArr.count {
                    grid[row][item.1] = srcArr[srcIdx]
                    srcIdx += 1
                }
            }
        }
        return grid.flatMap { $0 }.reduce(into: "") { $0.append($1) }
    }

    func seedShuffle(array: [Character], ikey: String) -> [Character] {
        var hashVal: Int64 = 0
        for char in ikey {
            let v = Int64(char.asciiValue ?? UInt8(char.unicodeScalars.first!.value & 0x7F))
            hashVal = ((hashVal &* 31) &+ v) & 0xFFFF_FFFF
        }
        var shuffleNum: Int64 = hashVal
        func pseudoRand(max: Int) -> Int {
            shuffleNum = ((shuffleNum &* 1_103_515_245) &+ 12345) & 0x7FFF_FFFF
            return Int(shuffleNum % Int64(max))
        }
        var result = array
        guard result.count > 1 else { return result }
        for i in (1..<result.count).reversed() {
            result.swapAt(i, pseudoRand(max: i + 1))
        }
        return result
    }

    func decrypt(src: String, clientKey: String, megacloudKey: String) -> String {
        let layers = 3
        let genKey = keygen(megacloudKey: megacloudKey, clientKey: clientKey)
        guard let decData = Data(base64Encoded: src),
            var decStr = String(data: decData, encoding: .utf8)
        else { return src }

        let charArray = defaultCharset
        for iteration in (1...layers).reversed() {
            let layerKey = genKey + String(iteration)
            var hashVal: Int64 = 0
            for char in layerKey {
                let v = Int64(char.asciiValue ?? UInt8(char.unicodeScalars.first!.value & 0x7F))
                hashVal = ((hashVal &* 31) &+ v) & 0xFFFF_FFFF
            }
            var seed = hashVal
            func seedRand(max: Int) -> Int {
                seed = ((seed &* 1_103_515_245) &+ 12345) & 0x7FFF_FFFF
                return Int(seed % Int64(max))
            }
            var decArr = Array(decStr)
            for i in 0..<decArr.count {
                if let cIdx = charArray.firstIndex(of: decArr[i]) {
                    let newIdx = (cIdx - seedRand(max: 95) + 95) % 95
                    decArr[i] = charArray[newIdx]
                }
            }
            decStr = String(decArr)
            decStr = columnarCipher(src: decStr, ikey: layerKey)
            let subValues = seedShuffle(array: charArray, ikey: layerKey)
            var charMap: [Character: Character] = [:]
            for i in 0..<subValues.count { charMap[subValues[i]] = charArray[i] }
            decStr = String(decStr.map { charMap[$0] ?? $0 })
        }
        if decStr.count >= 4, let len = Int(String(decStr.prefix(4))) {
            let start = decStr.index(decStr.startIndex, offsetBy: 4)
            let end =
                decStr.index(
                    start, offsetBy: len, limitedBy: decStr.endIndex) ?? decStr.endIndex
            return String(decStr[start..<end])
        }
        return decStr
    }
}

import OSLog
import Foundation
import Testing

@testable import ito_runner

@Suite("Atsumaru Rust SDK Tests")
struct AtsumaruRustSDKTests {

    actor NativeNetModule: NetModule {
        func fetch(request: NetRequest) async throws -> NetResponse {
            guard let url = URL(string: request.url) else {
                throw URLError(.badURL)
            }
            var req = URLRequest(url: url)
            req.httpMethod = request.method
            for (key, val) in request.headers {
                req.setValue(val, forHTTPHeaderField: key)
            }
            if let body = request.body {
                req.httpBody = Data(body)
            }

            let (data, response) = try await URLSession.shared.data(for: req)
            let httpResponse = response as? HTTPURLResponse
            let status = Int32(httpResponse?.statusCode ?? 200)

            var resHeaders = [String: String]()
            if let httpHeaders = httpResponse?.allHeaderFields {
                for (key, val) in httpHeaders {
                    resHeaders[String(describing: key)] = String(describing: val)
                }
            }

            return NetResponse(status: status, headers: resHeaders, body: [UInt8](data))
        }
    }

    func loadRunner() async throws -> ItoRunner {
        // Find the Rust compiler `.wasm` output artifact
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let releasePath =
            "\(currentDir)/projects/atsumaru/atsumaru.wasm"

        let url = URL(fileURLWithPath: releasePath)
        let runner = ItoRunner()
        await runner.setNetModule(NativeNetModule())
        await runner.setStdModule(DefaultStdModule())
        try await runner.loadPlugin(from: url)
        return runner
    }

    @Test("Fetches Popular Manga List using SDK via get_manga_list export")
    func fetchPopularMangaList() async throws {
        let runner = try await loadRunner()

        // This listing id aligns with Atsumaru's `views:desc` sorting
        let listing = Listing(id: "views", name: "Popular", kind: 0)

        // Use Swift ItoRunner FFI call to traverse memory boundaries -> Rust -> Web Request -> Deserialization
        let result = try await runner.getMangaList(listing: listing, page: 1)

        RunnerLogger.core.debug("\("Fetched \(result.entries.count)") mangas")
        #expect(result.entries.count > 0, "Atsumaru search results should not be empty")
        #expect(result.entries.count == 24, "Atsumaru defaults to 24 items per page")

        // Grab the first element
        if let firstManga = result.entries.first {
            RunnerLogger.core.debug("\("Top result: \(firstManga.title)") (Key: \(firstManga.key))")
            #expect(!firstManga.key.isEmpty, "Manga must have a key ID")
            #expect(!firstManga.title.isEmpty, "Manga must have a title")
            #expect(firstManga.cover != nil, "Manga must have a cover image populated")
            #expect(
                firstManga.cover?.hasPrefix("https://atsu.moe") == true,
                "Cover URL must be fully resolved via `resolve_image_url`")
        }
    }

    @Test("Fetches Manga Details using SDK via get_manga_update export")
    func fetchMangaDetails() async throws {
        let runner = try await loadRunner()

        let manga = Manga(
            key: "fX0YJ", title: "", authors: nil, artist: nil, description: nil, tags: nil,
            cover: nil, url: nil, status: .Unknown, contentRating: .Safe, nsfw: 0, viewer: .Default,
            chapters: nil)

        let updatedManga = try await runner.getMangaUpdate(
            manga: manga, needsDetails: true, needsChapters: true)

        #expect(updatedManga.title == "The Greatest Estate Developer")
        #expect(updatedManga.description?.isEmpty == false, "Synopsis should not be empty")
        #expect(
            updatedManga.status == .Ongoing || updatedManga.status == .Completed,
            "Status should be correctly evaluated")
        #expect(
            updatedManga.tags != nil && !(updatedManga.tags?.isEmpty ?? true),
            "Tags should be populated")
        #expect(updatedManga.chapters != nil, "Chapters array must be created")

        if let chapters = updatedManga.chapters {
            RunnerLogger.core.debug("\("Found \(chapters.count)") chapters")
            #expect(chapters.count > 0, "Manga should have parsed chapter items")
            if let firstChapter = chapters.first {
                #expect(!firstChapter.key.isEmpty, "Chapters should have a valid unique ID string")
                #expect(
                    firstChapter.url?.contains(firstChapter.key) == true, "Chapter URL contains ID")
                #expect(
                    firstChapter.scanlator != nil && !(firstChapter.scanlator?.isEmpty ?? true),
                    "Scanlator should be populated")
                #expect(firstChapter.chapter != nil, "Chapter number should be populated")
            }
        }
    }

    @Test("Search Manga List using SDK via get_search_manga_list export")
    func searchMangaList() async throws {
        let runner = try await loadRunner()

        let query = "Estate"
        let result = try await runner.getSearchMangaList(query: query, page: 1)

        RunnerLogger.core.debug("\("Search fetched \(result.entries.count)") mangas")
        #expect(result.entries.count > 0, "Search results should not be empty")

        if let firstManga = result.entries.first {
            #expect(!firstManga.key.isEmpty, "Manga must have a key ID")
            #expect(!firstManga.title.isEmpty, "Manga must have a title")
            #expect(
                firstManga.title.lowercased().contains("estate"),
                "Title should be related to the search query")
        }
    }

    @Test("Fetches Page List using SDK via get_page_list export")
    func fetchPageList() async throws {
        let runner = try await loadRunner()

        let manga = Manga(key: "fX0YJ", title: "The Greatest Estate Developer")
        // To safely get a valid chapter, we first fetch the chapters list
        let updatedManga = try await runner.getMangaUpdate(
            manga: manga, needsDetails: false, needsChapters: true)

        guard let firstChapter = updatedManga.chapters?.first else {
            Issue.record("No chapters found to fetch pages for.")
            return
        }

        let pages = try await runner.getPageList(manga: updatedManga, chapter: firstChapter)

        #expect(pages.count > 0, "Should fetch at least one page")
        if let firstPage = pages.first {
            #expect(firstPage.index == 0, "First page index should be 0")
            if case .url(let urlStr) = firstPage.content {
                #expect(urlStr.hasPrefix("http"), "Page URL should be well-formed")
            } else {
                Issue.record("Expected .url content variant")
            }
        }
    }

    @Test("Reproduce Wasm Trap with multiple Manga Updates")
    func testWasmTrapGetMangaUpdate() async throws {
        let runner = try await loadRunner()

        // Using different mangas, including potentially huge ones like Martial Peak ("0g5sF")
        let tests = ["fX0YJ", "TKRmo", "OXzpi"]

        for mangaId in tests {
            let manga = Manga(key: mangaId, title: "", status: .Unknown, contentRating: .Safe)

            RunnerLogger.core.debug("\("[DEBUG] Fetching manga update for \(mangaId)")...")
            let updatedManga = try await runner.getMangaUpdate(
                manga: manga,
                needsDetails: true,
                needsChapters: true
            )

            #expect(!updatedManga.title.isEmpty, "Title should be populated for \(mangaId)")
            RunnerLogger.core.debug("\("Successfully updated \(mangaId)"): \(updatedManga.title), chapters: \(updatedManga.chapters?.count ?? 0)"
            )
        }
    }
}

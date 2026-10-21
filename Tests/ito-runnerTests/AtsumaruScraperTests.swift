import OSLog
import Foundation
import Testing

@testable import ito_runner

@Suite("Atsumaru Scraper Tests")
struct AtsumaruScraperTests {

    let baseURL = "https://atsu.moe"
    let apiBase = "https://atsu.moe/api"
    let searchURL = "https://atsu.moe/collections/manga/documents/search"

    // MARK: - Models from `models.rs` mapped to Swift

    struct SearchResponse: Decodable {
        let hits: [SearchHit]
        let found: Int
        let page: Int
    }

    struct SearchHit: Decodable {
        let document: SearchDocument
    }

    struct SearchDocument: Decodable {
        let id: String?
        let title: String?
        let poster: String?
        let status: String?
        let synopsis: String?
        let tags: [String]?
        let authors: [String]?
    }

    struct MangaPageWrapper: Decodable {
        let mangaPage: MangaPageDetail
    }

    struct MangaPageDetail: Decodable {
        let id: String?
        let title: String?
        let englishTitle: String?
        let poster: ImageAsset?
        let banner: ImageAsset?
        let status: String?
        let synopsis: String?
        let scanlators: [Scanlator]?
        let genres: [Entity]?
        let authors: [Entity]?
    }

    struct ImageAsset: Decodable {
        let image: String?
    }

    struct Entity: Decodable {
        let id: String?
        let name: String?
    }

    struct Scanlator: Decodable {
        let id: String
        let name: String
    }

    struct ChapterListResponse: Decodable {
        let chapters: [ChapterItem]
    }

    struct ChapterItem: Decodable {
        let id: String
        let title: String?
        let number: Float
        let createdAt: Int64
        let scanlationMangaId: String?
    }

    struct ChapterPageResponse: Decodable {
        let readChapter: ReadChapter
    }

    struct ReadChapter: Decodable {
        let id: String
        let title: String?
        let pages: [ChapterPageItem]
    }

    struct ChapterPageItem: Decodable {
        let id: String
        let image: String
        let number: Int
    }

    // MARK: - Helper Methods from `lib.rs`

    func resolveImageURL(_ path: String) -> String {
        if path.hasPrefix("http") {
            return path
        } else if path.hasPrefix("/static/") || path.hasPrefix("static/") {
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return "\(baseURL)/\(normalized)"
        } else if path.hasPrefix("/") {
            return "\(baseURL)\(path)"
        } else {
            return "\(baseURL)/static/\(path)"
        }
    }

    func buildMangaFromDoc(_ doc: SearchDocument) -> Manga {
        var status: Manga.Status = .Unknown
        switch doc.status {
        case "Ongoing": status = .Ongoing
        case "Completed": status = .Completed
        case "Hiatus": status = .Hiatus
        case "Dropped", "Cancelled": status = .Cancelled
        default: status = .Unknown
        }

        return Manga(
            key: doc.id ?? "",
            title: doc.title ?? "",
            authors: doc.authors?.first.map { [$0] },
            artist: nil,
            description: doc.synopsis,
            tags: doc.tags,
            cover: doc.poster.map(resolveImageURL),
            url: "\(baseURL)/manga/\(doc.id ?? "")",
            status: status,
            contentRating: .Safe,
            viewer: .Webtoon
        )
    }

    // Network Request Wrapper Wrapper
    func fetchJSON<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("ito-runner/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Tests

    @Test("Fetch Search results from Atsumaru API")
    func testFetchSearch() async throws {
        // Query: "Absolute Regression" URL equivalent
        let q = "*"
        let page = 1
        let perPage = 24
        let sortField = "views"
        let sortOrder = "desc"

        let url =
            "\(searchURL)?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)&page=\(page)&per_page=\(perPage)&query_by=title,englishTitle,otherNames,authors&include_fields=id,title,englishTitle,poster,posterSmall,posterMedium,type,isAdult,status,year,synopsis,tags,authors&sort_by=\(sortField):\(sortOrder)"

        let response: SearchResponse = try await fetchJSON(url)
        let entries = response.hits.map { buildMangaFromDoc($0.document) }

        #expect(!entries.isEmpty, "Search should return some results")
        #expect(response.page == page)

        if let first = entries.first {
            #expect(!first.key.isEmpty)
            #expect(!first.title.isEmpty)
            RunnerLogger.core.debug("First manga from search: \(first.title)")
        }
    }

    @Test("Fetch Manga page and chapters from Atsumaru API")
    func testGetMangaUpdate() async throws {
        // "TKRmo" is "Absolute Regression" based on the user's `lib.rs`
        let mangaId = "TKRmo"
        var manga = Manga(
            key: mangaId, title: "", authors: nil, artist: nil, description: nil,
            tags: nil, cover: nil, url: nil, status: .Unknown, contentRating: .Safe, nsfw: 0,
            viewer: .Default)

        // 1. Fetch Details
        let detailURL = "\(apiBase)/manga/page?id=\(mangaId)"
        let detailResponse: MangaPageWrapper = try await fetchJSON(detailURL)
        let detail = detailResponse.mangaPage

        manga.title = detail.title ?? ""
        manga.description = detail.synopsis
        manga.cover = detail.poster?.image.map(resolveImageURL)
        manga.url = "\(baseURL)/manga/\(detail.id ?? "")"

        switch detail.status {
        case "Ongoing": manga.status = Manga.Status.Ongoing
        case "Completed": manga.status = Manga.Status.Completed
        case "Hiatus": manga.status = Manga.Status.Hiatus
        case "Dropped", "Cancelled": manga.status = Manga.Status.Cancelled
        default: manga.status = Manga.Status.Unknown
        }

        let authors = (detail.authors ?? []).compactMap { $0.name }
        if !authors.isEmpty {
            manga.authors = authors
        }

        let tags = (detail.genres ?? []).compactMap { $0.name }
        if !tags.isEmpty {
            manga.tags = tags
        }

        var scanlatorMap: [String: String] = [:]
        if let scanlators = detail.scanlators {
            for s in scanlators {
                scanlatorMap[s.id] = s.name
            }
        }

        #expect(!manga.title.isEmpty, "Manga title should be populated")
        #expect(manga.cover != nil, "Manga cover should be populated")
        RunnerLogger.core.debug("Updated Manga: \(manga.title) - \(String(describing: manga.status))")

        // 2. Fetch Chapters
        let chaptersURL = "\(apiBase)/manga/allChapters?mangaId=\(mangaId)"
        let chaptersResponse: ChapterListResponse = try await fetchJSON(chaptersURL)

        var chapters: [Manga.Chapter] = []
        for chap in chaptersResponse.chapters {
            let chapterUrl = "\(baseURL)/read/\(mangaId)?chapterId=\(chap.id)"
            let scanlatorName = chap.scanlationMangaId.flatMap { scanlatorMap[$0] }

            chapters.append(
                Manga.Chapter(
                    key: chap.id,
                    title: chap.title,
                    volume: nil,
                    chapter: chap.number,
                    dateUpdated: Double(chap.createdAt) / 1000.0,
                    scanlator: scanlatorName,
                    url: chapterUrl,
                    lang: "en",
                    paywalled: nil
                ))
        }

        // Sort chapters descending by chapter number
        // (If chapter format changes, adjust this logic)
        chapters.sort { ($0.chapter ?? 0) > ($1.chapter ?? 0) }

        #expect(!chapters.isEmpty, "Chapters should not be empty")

        if let first = chapters.first {
            #expect(!first.key.isEmpty)
            #expect(first.chapter != nil)
            RunnerLogger.core.debug(
                "Successfully loaded \(chapters.count) chapters. First chapter is \(first.chapter ?? 0) by \(first.scanlator ?? "Unknown")"
            )
        }

        // We can optionally test get_page_list with the first chapter
        if let firstChap = chapters.first {
            let pageURL = "\(apiBase)/read/chapter?mangaId=\(mangaId)&chapterId=\(firstChap.key)"
            let pageResponse: ChapterPageResponse = try await fetchJSON(pageURL)

            let pages = pageResponse.readChapter.pages.map { p in
                Page(
                    index: Int32(p.number),
                    content: .url(resolveImageURL(p.image)),
                    hasDescription: false
                )
            }

            #expect(!pages.isEmpty, "Pages should not be empty")
            RunnerLogger.core.debug("\("Chapter \(firstChap.chapter ?? 0)") contains \(pages.count) pages.")
        }
    }
}

extension Array {
    fileprivate mutating func push(_ newElement: Element) {
        self.append(newElement)
    }
}

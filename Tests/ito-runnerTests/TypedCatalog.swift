import Foundation
@testable import ito_runner

/// Typed views of the kind-neutral catalog API, for tests of single-kind scrapers. An entry of
/// another kind fails the call rather than being dropped.
extension ItoRunner {
    func getMangaList(listing: Listing, page: Int32) async throws -> Manga.PageResult {
        let result = try await getListing(listing, page: page)
        return Manga.PageResult(entries: try result.entries.map { try $0.require(\.manga) }, hasNextPage: result.hasNextPage)
    }

    func getSearchMangaList(query: String, page: Int32) async throws -> Manga.PageResult {
        let result = try await search(query: query, page: page, kind: .manga)
        return Manga.PageResult(entries: try result.entries.map { try $0.require(\.manga) }, hasNextPage: result.hasNextPage)
    }

    func getMangaUpdate(manga: Manga, needsDetails: Bool, needsChapters: Bool) async throws -> Manga {
        try await getMediaUpdate(.manga(manga), needsDetails: needsDetails, needsUnits: needsChapters).require(\.manga)
    }

    func getPageList(manga: Manga, chapter: Manga.Chapter) async throws -> [Page] {
        try await getChapterPages(entry: .manga(manga), chapter: chapter)
    }

    func getAnimeList(listing: Listing, page: Int32) async throws -> Anime.PageResult {
        let result = try await getListing(listing, page: page)
        return Anime.PageResult(entries: try result.entries.map { try $0.require(\.anime) }, hasNextPage: result.hasNextPage)
    }

    func getAnimeUpdate(anime: Anime, needsDetails: Bool, needsEpisodes: Bool) async throws -> Anime {
        try await getMediaUpdate(.anime(anime), needsDetails: needsDetails, needsUnits: needsEpisodes).require(\.anime)
    }

    func getVideoList(anime: Anime, episode: Anime.Episode) async throws -> [Anime.Video] {
        try await getEpisodeVideos(anime: anime, episode: episode)
    }

    func markChapterRead(mediaKey: String, chapterKey: String) async throws -> Bool {
        try await markCompleted(kind: .manga, mediaKey: mediaKey, unitKey: chapterKey)
    }

    func markEpisodeWatched(mediaKey: String, episodeKey: String) async throws -> Bool {
        try await markCompleted(kind: .anime, mediaKey: mediaKey, unitKey: episodeKey)
    }
}

extension MediaEntry {
    var manga: Manga? {
        if case .manga(let manga) = self { return manga }
        return nil
    }

    var anime: Anime? {
        if case .anime(let anime) = self { return anime }
        return nil
    }

    var novel: Novel? {
        if case .novel(let novel) = self { return novel }
        return nil
    }

    /// The entry as the kind a single-kind test expects.
    func require<T>(_ kind: KeyPath<MediaEntry, T?>) throws -> T {
        guard let value = self[keyPath: kind] else {
            throw ItoError.wasmTrap("Expected another kind of entry than \(self.kind)")
        }
        return value
    }
}

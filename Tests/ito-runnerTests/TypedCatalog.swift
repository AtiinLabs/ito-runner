import Foundation
@testable import ito_runner

/// Typed views of the kind-neutral catalog API, for tests of single-kind scrapers.
extension ItoRunner {
    func getMangaList(listing: Listing, page: Int32) async throws -> Manga.PageResult {
        let result = try await getListing(listing, page: page)
        return Manga.PageResult(entries: result.entries.compactMap(\.manga), hasNextPage: result.hasNextPage)
    }

    func getSearchMangaList(query: String, page: Int32) async throws -> Manga.PageResult {
        let result = try await search(query: query, page: page, kind: .manga)
        return Manga.PageResult(entries: result.entries.compactMap(\.manga), hasNextPage: result.hasNextPage)
    }

    func getMangaUpdate(manga: Manga, needsDetails: Bool, needsChapters: Bool) async throws -> Manga {
        let updated = try await getMediaUpdate(.manga(manga), needsDetails: needsDetails, needsUnits: needsChapters)
        guard let manga = updated.manga else { throw ItoError.wasmTrap("Expected a manga") }
        return manga
    }

    func getPageList(manga: Manga, chapter: Manga.Chapter) async throws -> [Page] {
        try await getChapterPages(entry: .manga(manga), chapter: chapter)
    }

    func getAnimeList(listing: Listing, page: Int32) async throws -> Anime.PageResult {
        let result = try await getListing(listing, page: page)
        return Anime.PageResult(entries: result.entries.compactMap(\.anime), hasNextPage: result.hasNextPage)
    }

    func getAnimeUpdate(anime: Anime, needsDetails: Bool, needsEpisodes: Bool) async throws -> Anime {
        let updated = try await getMediaUpdate(.anime(anime), needsDetails: needsDetails, needsUnits: needsEpisodes)
        guard let anime = updated.anime else { throw ItoError.wasmTrap("Expected an anime") }
        return anime
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
}

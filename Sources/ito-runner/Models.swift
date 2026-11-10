import Foundation

public struct PluginManifest: Codable, Sendable {
    public let info: PluginInfo

    public init(info: PluginInfo) {
        self.info = info
    }

    // Custom decoder to handle when the JSON is directly PluginInfo without the "info" wrapper
    public init(from decoder: Decoder) throws {
        // Try to decode as if it has an "info" wrapper (old format)
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let info = try? container.decode(PluginInfo.self, forKey: .info) {
            self.info = info
        } else {
            // Otherwise, decode the root as PluginInfo (new format)
            self.info = try PluginInfo(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case info
    }
}

/// What a catalog entry is. A plugin may serve several kinds (`PluginInfo.supportedKinds`).
/// Matches the SDK's `MediaKind`; manifests name kinds by their raw value.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case manga
    case anime
    case novel

    /// The SDK's `MediaKind` value, as plugin exports take it.
    public var wireValue: Int32 {
        switch self {
        case .manga: return 0
        case .anime: return 1
        case .novel: return 2
        }
    }

    /// How a chapter of this kind of entry is read when its plugin doesn't say.
    public var defaultContentKind: ContentKind {
        self == .novel ? .text : .images
    }
}

/// How a chapter is read, whatever its entry's kind: `images` in the page reader, `text` in the
/// text reader, which lays out text pages and shows image pages inline. Matches the SDK's
/// `ContentKind`; stored by name, sent to plugins by `wireValue`.
public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case images
    case text

    /// The SDK's `ContentKind` value, as plugins lay it out.
    public var wireValue: Int32 {
        switch self {
        case .images: return 0
        case .text: return 1
        }
    }

    public init?(wireValue: Int32) {
        guard let kind = Self.allCases.first(where: { $0.wireValue == wireValue }) else { return nil }
        self = kind
    }
}

/// A native image fetch resolved by a plugin. Hosts authorize the URL against the plugin's
/// configured image origins before attaching these private headers, and reject cross-origin
/// redirects. This is a transient request, not the persisted plugin-owned image locator.
public struct PluginImageRequest: Codable, Equatable, Sendable {
    public let url: String
    @PostcardOptionalMapCoded public var headers: [String: String]?

    public init(url: String, headers: [String: String]? = nil) {
        self.url = url
        self._headers = PostcardOptionalMapCoded(wrappedValue: headers)
    }
}

public struct SettingsSchema: Codable, Sendable {
    public var settings: [Setting]
}

/// A non-destructive diagnostic declared independently of the ABI-1 settings schema.
public struct SettingsAction: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String?

    public init(id: String, title: String, summary: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}

/// Advisory validation; an empty key denotes a form-level issue.
public struct SettingIssue: Codable, Equatable, Sendable {
    public let key: String
    public let message: String

    public init(key: String, message: String) {
        self.key = key
        self.message = message
    }
}

public enum Setting: Codable, Sendable, PostcardEnumMarker {
    case toggle(id: String, name: String, summary: String?, defaultValue: Bool)
    case text(id: String, name: String, summary: String?, defaultValue: String)
    case picker(id: String, name: String, summary: String?, options: [String], defaultValue: String)
    /// A credential. Hosts keep it out of plain storage and backups and never display it.
    case secret(id: String, name: String, summary: String?)

    enum CodingKeys: Int, CodingKey, PostcardEnumKeys {
        case toggle = 0
        case text = 1
        case picker = 2
        case secret = 3
    }
}

public struct PluginInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let minAppVersion: String
    public let url: String?
    public let sourceUrl: String?
    public let contentRating: ContentRating?
    public let nsfw: Int?
    public let language: String?
    public let languages: [String]?
    /// The plugin's primary kind. Older hosts read only this.
    public let type: MediaKind
    /// Every kind the plugin serves, as its packager recorded them; nil for plugins built before
    /// plugins could serve several.
    public let kinds: [MediaKind]?
    public let author: String?
    public let description: String?
    public let tags: [String]?
    public let archived: Bool?
    public let archivedReason: String?
    public let archivedDate: String?
    /// The ABI version the plugin was built for (`ito_abi_version`), as its packager recorded it.
    public let abi: Int?
    /// The SDK the plugin was built with, such as "ito-rs 0.1.0".
    public let sdk: String?
    /// The host functions the plugin imports, as "module.name" (e.g. "ito:core/net.fetch_v2"), as
    /// its packager read them. Lets a host refuse a plugin it can't run before downloading it.
    public let imports: [String]?

    public init(
        id: String, name: String, version: String, minAppVersion: String, url: String? = nil,
        sourceUrl: String? = nil, contentRating: ContentRating? = nil,
        nsfw: Int? = nil, language: String? = nil, languages: [String]? = nil,
        type: MediaKind = .manga, kinds: [MediaKind]? = nil, author: String? = nil,
        description: String? = nil, tags: [String]? = nil,
        archived: Bool? = nil, archivedReason: String? = nil, archivedDate: String? = nil,
        abi: Int? = nil, sdk: String? = nil, imports: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minAppVersion = minAppVersion
        self.url = url
        self.sourceUrl = sourceUrl
        self.contentRating = contentRating
        self.nsfw = nsfw
        self.language = language
        self.languages = languages
        self.type = type
        self.kinds = kinds
        self.author = author
        self.description = description
        self.tags = tags
        self.archived = archived
        self.archivedReason = archivedReason
        self.archivedDate = archivedDate
        self.abi = abi
        self.sdk = sdk
        self.imports = imports
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, minAppVersion = "min_app_version", url, sourceUrl, contentRating, nsfw, language, languages, type, kinds, author, description, tags, archived, archivedReason = "archived_reason", archivedDate = "archived_date", abi, sdk, imports
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)

        // Handle both Int (old format) and String (new SemVer format)
        if let intVersion = try? container.decode(Int.self, forKey: .version) {
            self.version = String(intVersion)
        } else {
            self.version = try container.decode(String.self, forKey: .version)
        }

        self.minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "1.0.0"
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.sourceUrl = try container.decodeIfPresent(String.self, forKey: .sourceUrl)
        self.contentRating = try container.decodeIfPresent(
            ContentRating.self, forKey: .contentRating)
        self.nsfw = try container.decodeIfPresent(Int.self, forKey: .nsfw)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.languages = try container.decodeIfPresent([String].self, forKey: .languages)
        self.type = try container.decodeIfPresent(MediaKind.self, forKey: .type) ?? .manga
        self.kinds = try container.decodeIfPresent([MediaKind].self, forKey: .kinds)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags)
        self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
        self.archivedReason = try container.decodeIfPresent(String.self, forKey: .archivedReason)
        self.archivedDate = try container.decodeIfPresent(String.self, forKey: .archivedDate)
        self.abi = try container.decodeIfPresent(Int.self, forKey: .abi)
        self.sdk = try container.decodeIfPresent(String.self, forKey: .sdk)
        self.imports = try container.decodeIfPresent([String].self, forKey: .imports)
    }

    /// Every kind the plugin serves.
    public var supportedKinds: [MediaKind] {
        kinds ?? [type]
    }
}

/// What kind of failure a plugin reported, so the host can offer the right way out. Sent by
/// plugins through their `ito_last_error` export; matches the SDK's `ErrorCategory`.
public enum PluginErrorCategory: Int32, Codable, Sendable, PostcardEnumMarker {
    /// The plugin needs settings it doesn't have (e.g. a server address).
    case needsSetup = 0
    /// The service rejected the plugin's credentials.
    case unauthorized = 1
    /// The service couldn't be reached.
    case network = 2
    /// The service answered with an error of its own.
    case server = 3
    /// What was asked for doesn't exist.
    case notFound = 4
    /// Anything else.
    case other = 5
    /// Explicit non-participation in an optional export (error protocol version 2).
    case unsupported = 6
    /// The service needs the user to sign in on its website.
    case needsLogin = 7
    /// The plugin's response broke the data contract; its message is a fixed rule code
    /// (`CatalogContractViolation.Rule`). Never shown to users.
    case contractViolation = 8
}

/// The failure a plugin reports through `ito_last_error`.
public struct PluginErrorPayload: Codable, Sendable {
    public let category: PluginErrorCategory
    public let message: String
}

public enum ContentRating: Int32, Codable, Sendable, PostcardEnumMarker {
    case Safe = 0
    case Suggestive = 1  // Ecchi
    case Nsfw = 2  // Pornographic
}

/// The scanlation group of a chapter as plugins lay it out: an optional source-scoped identifier
/// and the display name. `Chapter` flattens it into `scanlator` (the name) and `scanlatorID`.
struct ScanlatorDescriptor: Codable, Sendable, Equatable {
    var id: String?
    var name: String
}

/// Which chapters a returned list covers. The raw values are the wire format. A value this
/// runner doesn't know reads as `unknown`, in plugin payloads and in stored JSON alike, so a list
/// from a later release (or a blob written by one) stays readable.
public enum CatalogScope: Int32, Codable, Sendable, PostcardEnumMarker {
    case unknown = 0
    /// What the source shows by default, which may collapse alternative uploads.
    case visible = 1
    /// Every eligible alternative upload is listed.
    case allEligible = 2

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int32.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

/// Whether a chapter list holds everything within its `CatalogScope`, for the signed-in account
/// and the source settings in effect. A value this runner doesn't know reads as `unknown`.
public enum CatalogCompleteness: Int32, Codable, Sendable, PostcardEnumMarker {
    case unknown = 0
    case partial = 1
    case complete = 2

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int32.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

/// What an entry's chapter list covers. An entry without one has an unknown scope and
/// completeness. A catalog requires the entry's `chapters`.
public struct ChapterCatalog: Codable, Sendable, Equatable {
    public var scope: CatalogScope
    public var completeness: CatalogCompleteness

    public init(scope: CatalogScope = .unknown, completeness: CatalogCompleteness = .unknown) {
        self.scope = scope
        self.completeness = completeness
    }
}

/// A chapter of a manga or novel (`Manga.Chapter`, `Novel.Chapter`): one exact upload.
public struct Chapter: Codable, Sendable, Identifiable {
    public var id: String { key }
    /// Identifies this exact upload within its entry.
    public var key: String
    public var title: String?
    public var volume: Double?
    public var chapter: Double?
    /// When the upload was published, in seconds since 1970-01-01 UTC.
    public var dateUpdated: Double?
    /// The scanlation group's display name.
    public var scanlator: String?
    /// A stable identifier of the group within the source, when the source has one. Only
    /// meaningful with a `scanlator` name.
    public var scanlatorID: String?
    public var url: String?
    public var lang: String?
    /// Locked for the signed-in account or session. Nil means unknown.
    public var paywalled: Bool?
    /// How the chapter is read. Nil only when it was stored before per-chapter kinds; it is then
    /// read as its entry's kind says (`MediaKind.defaultContentKind`).
    public var kind: ContentKind?
    /// Shared by every upload of one entry that the source declares to be the same reading position.
    public var logicalUnitID: String?
    /// Orders reading positions within one response: lower is read earlier, equal values mean the
    /// same position. Not durable across refreshes.
    public var readingOrder: Int64?
    /// A token that changes exactly when the upload's content changes.
    public var revision: String?

    public init(
        key: String, title: String? = nil, volume: Double? = nil, chapter: Double? = nil,
        dateUpdated: Double? = nil, scanlator: String? = nil, scanlatorID: String? = nil,
        url: String? = nil, lang: String? = nil, paywalled: Bool? = nil, kind: ContentKind? = nil,
        logicalUnitID: String? = nil, readingOrder: Int64? = nil, revision: String? = nil
    ) {
        self.key = key
        self.title = title
        self.volume = volume
        self.chapter = chapter
        self.dateUpdated = dateUpdated
        self.scanlator = scanlator
        self.scanlatorID = scanlatorID
        self.url = url
        self.lang = lang
        self.paywalled = paywalled
        self.kind = kind
        self.logicalUnitID = logicalUnitID
        self.readingOrder = readingOrder
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey {
        case key, title, volume, chapter, dateUpdated, scanlator, scanlatorID = "scanlatorId", url, lang
        case paywalled, kind, logicalUnitID = "logicalUnitId", readingOrder, revision
    }

    /// The only plugin ABI with a chapter layout.
    private static let wireABI = 3

    // Plugins lay a chapter out as the ABI 3 SDK does: the scanlator is an optional descriptor, the
    // kind is always present and the three fields after it are optional. Other formats (JSON)
    // keep the scanlator's name under `scanlator`, carry the kind when it is known, and treat
    // every key added since the first stored blobs as optional, so older blobs still decode.
    public init(from decoder: Decoder) throws {
        let abi = decoder.userInfo[postcardABIVersionKey] as? Int
        if let abi, abi != Self.wireABI { throw ItoError.postcardDecodingError("A chapter has no layout for ABI \(abi)") }
        let isWire = abi != nil
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume)
        chapter = try container.decodeIfPresent(Double.self, forKey: .chapter)
        dateUpdated = try container.decodeIfPresent(Double.self, forKey: .dateUpdated)
        if isWire {
            let descriptor = try container.decodeIfPresent(ScanlatorDescriptor.self, forKey: .scanlator)
            scanlator = descriptor?.name
            scanlatorID = descriptor?.id
        } else {
            scanlator = try container.decodeIfPresent(String.self, forKey: .scanlator)
            scanlatorID = try container.decodeIfPresent(String.self, forKey: .scanlatorID)
        }
        url = try container.decodeIfPresent(String.self, forKey: .url)
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        paywalled = try container.decodeIfPresent(Bool.self, forKey: .paywalled)
        if isWire {
            let value = try container.decode(Int32.self, forKey: .kind)
            guard let decoded = ContentKind(wireValue: value) else {
                throw CatalogContractViolation(.enumUnknown)
            }
            kind = decoded
        } else {
            kind = try container.decodeIfPresent(ContentKind.self, forKey: .kind)
        }
        logicalUnitID = try container.decodeIfPresent(String.self, forKey: .logicalUnitID)
        readingOrder = try container.decodeIfPresent(Int64.self, forKey: .readingOrder)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
    }

    public func encode(to encoder: Encoder) throws {
        let abi = encoder.userInfo[postcardABIVersionKey] as? Int
        if let abi, abi != Self.wireABI { throw ItoError.postcardEncodingError("A chapter has no layout for ABI \(abi)") }
        let isWire = abi != nil
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(volume, forKey: .volume)
        try container.encodeIfPresent(chapter, forKey: .chapter)
        try container.encodeIfPresent(dateUpdated, forKey: .dateUpdated)
        if isWire {
            if scanlator == nil, scanlatorID != nil {
                throw ItoError.postcardEncodingError("A chapter has a scanlator identifier but no scanlator name.")
            }
            let descriptor = scanlator.map { ScanlatorDescriptor(id: scanlatorID, name: $0) }
            try container.encodeIfPresent(descriptor, forKey: .scanlator)
        } else {
            try container.encodeIfPresent(scanlator, forKey: .scanlator)
            try container.encodeIfPresent(scanlatorID, forKey: .scanlatorID)
        }
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(lang, forKey: .lang)
        try container.encodeIfPresent(paywalled, forKey: .paywalled)
        if isWire {
            // The runner resolves unknown kinds before sending a chapter to a plugin.
            guard let kind else {
                throw ItoError.postcardEncodingError("A chapter sent to the plugin has no kind.")
            }
            try container.encode(kind.wireValue, forKey: .kind)
        } else {
            try container.encodeIfPresent(kind, forKey: .kind)
        }
        try container.encodeIfPresent(logicalUnitID, forKey: .logicalUnitID)
        try container.encodeIfPresent(readingOrder, forKey: .readingOrder)
        try container.encodeIfPresent(revision, forKey: .revision)
    }
}

public struct Manga: Codable, Sendable, Identifiable {
    public var id: String { key }

    public enum Status: Int32, Codable, Sendable, PostcardEnumMarker {
        case Unknown = 0
        case Ongoing = 1
        case Completed = 2
        case Cancelled = 3
        case Hiatus = 4
    }

    public enum Viewer: Int32, Codable, Sendable, PostcardEnumMarker {
        case Default = 0
        case Rtl = 1
        case Ltr = 2
        case Vertical = 3
        case Webtoon = 4
    }

    public typealias Chapter = ito_runner.Chapter

    public var key: String
    public var title: String
    public var authors: [String]?
    public var artist: String?
    public var description: String?
    public var tags: [String]?
    public var cover: String?
    public var url: String?
    public var status: Status
    public var contentRating: ContentRating
    public var nsfw: Int32
    public var viewer: Viewer
    public var chapters: [Chapter]?
    /// What `chapters` covers. Nil means unknown, and it is nil when `chapters` is.
    public var catalog: ChapterCatalog?

    public init(
        key: String, title: String, authors: [String]? = nil, artist: String? = nil,
        description: String? = nil, tags: [String]? = nil, cover: String? = nil, url: String? = nil,
        status: Status = .Unknown, contentRating: ContentRating = .Safe, nsfw: Int32 = 0,
        viewer: Viewer = .Default, chapters: [Chapter]? = nil, catalog: ChapterCatalog? = nil
    ) {
        self.key = key
        self.title = title
        self.authors = authors
        self.artist = artist
        self.description = description
        self.tags = tags
        self.cover = cover
        self.url = url
        self.status = status
        self.contentRating = contentRating
        self.nsfw = nsfw
        self.viewer = viewer
        self.chapters = chapters
        self.catalog = catalog
    }
}

public struct Novel: Codable, Sendable, Identifiable {
    public var id: String { key }

    public enum Status: Int32, Codable, Sendable, PostcardEnumMarker {
        case Unknown = 0
        case Ongoing = 1
        case Completed = 2
        case Cancelled = 3
        case Hiatus = 4
    }

    public typealias Chapter = ito_runner.Chapter

    public var key: String
    public var title: String
    public var authors: [String]?
    public var artist: String?
    public var description: String?
    public var tags: [String]?
    public var cover: String?
    public var url: String?
    public var status: Status
    public var contentRating: ContentRating
    public var nsfw: Int32
    public var chapters: [Chapter]?
    /// What `chapters` covers. Nil means unknown, and it is nil when `chapters` is.
    public var catalog: ChapterCatalog?

    public init(
        key: String, title: String, authors: [String]? = nil, artist: String? = nil,
        description: String? = nil, tags: [String]? = nil, cover: String? = nil, url: String? = nil,
        status: Status = .Unknown, contentRating: ContentRating = .Safe, nsfw: Int32 = 0,
        chapters: [Chapter]? = nil, catalog: ChapterCatalog? = nil
    ) {
        self.key = key
        self.title = title
        self.authors = authors
        self.artist = artist
        self.description = description
        self.tags = tags
        self.cover = cover
        self.url = url
        self.status = status
        self.contentRating = contentRating
        self.nsfw = nsfw
        self.chapters = chapters
        self.catalog = catalog
    }
}

public enum PageContent: Codable, Sendable, PostcardEnumMarker {
    case url(String)
    case text(String)

    enum CodingKeys: Int, CodingKey, PostcardEnumKeys {
        case url = 0
        case text = 1
    }
}

public struct Page: Codable, Sendable {
    public var index: Int32
    public var content: PageContent
    public var hasDescription: Bool
    public var description: String?
    @PostcardOptionalMapCoded public var headers: [String: String]?

    public init(
        index: Int32, content: PageContent, hasDescription: Bool = false, description: String? = nil, headers: [String: String]? = nil
    ) {
        self.index = index
        self.content = content
        self.hasDescription = hasDescription
        self.description = description
        self._headers = PostcardOptionalMapCoded(wrappedValue: headers)
    }
}

public struct Listing: Codable, Sendable {
    public var id: String
    public var name: String
    /// Reserved; hosts pass it back to the plugin unchanged.
    public var kind: Int32

    public init(id: String, name: String, kind: Int32) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum FilterValue: Codable, Sendable, PostcardEnumMarker {
    case boolean(Bool)
    case int(Int64)
    case float(Double)
    case string(String)

    enum CodingKeys: Int, CodingKey, PostcardEnumKeys {
        case boolean = 0
        case int = 1
        case float = 2
        case string = 3
    }
}

public struct FilterItem: Codable, Sendable {
    public var type: String
    public var name: String
    public var value: FilterValue

    public init(type: String, name: String, value: FilterValue) {
        self.type = type
        self.name = name
        self.value = value
    }
}

public struct Link: Codable, Sendable {
    public var title: String
    public var value: LinkValue?

    public init(title: String, value: LinkValue? = nil) {
        self.title = title
        self.value = value
    }
}

public struct NovelWithChapter: Codable, Sendable {
    public var novel: Novel
    public var chapter: Novel.Chapter

    public init(novel: Novel, chapter: Novel.Chapter) {
        self.novel = novel
        self.chapter = chapter
    }
}

public enum LinkValue: Codable, Sendable, PostcardEnumMarker {
    case url(String)
    case manga(Manga)
    case anime(Anime)
    case novel(Novel)
    case listing(Listing)

    enum CodingKeys: Int, CodingKey, PostcardEnumKeys {
        case url = 0
        case manga = 1
        case anime = 2
        case novel = 3
        case listing = 4
    }
}

public struct MangaWithChapter: Codable, Sendable {
    public var manga: Manga
    public var chapter: Manga.Chapter

    public init(manga: Manga, chapter: Manga.Chapter) {
        self.manga = manga
        self.chapter = chapter
    }
}

public struct AnimeWithEpisode: Codable, Sendable {
    public var anime: Anime
    public var episode: Anime.Episode

    public init(anime: Anime, episode: Anime.Episode) {
        self.anime = anime
        self.episode = episode
    }
}

public struct Anime: Codable, Sendable, Identifiable {
    public var id: String { key }

    public enum Status: Int32, Codable, Sendable, PostcardEnumMarker {
        case Unknown = 0
        case Ongoing = 1
        case Completed = 2
        case Cancelled = 3
        case Hiatus = 4
    }

    public struct Episode: Codable, Sendable, Identifiable {
        public var id: String { key }
        public var key: String
        public var title: String?
        public var episode: Float32?
        public var dateUpdated: Double?
        public var url: String?
        public var lang: String?
        public var paywalled: Bool?

        public init(
            key: String, title: String? = nil, episode: Float32? = nil, dateUpdated: Double? = nil,
            url: String? = nil, lang: String? = nil, paywalled: Bool? = nil
        ) {
            self.key = key
            self.title = title
            self.episode = episode
            self.dateUpdated = dateUpdated
            self.url = url
            self.lang = lang
            self.paywalled = paywalled
        }
    }

    public struct AudioTrack: Codable, Sendable {
        public var url: String
        public var language: String

        public init(url: String, language: String) {
            self.url = url
            self.language = language
        }
    }

    public struct Subtitle: Codable, Sendable {
        public var url: String
        public var language: String
        public var format: String
        public var isHardsub: Bool

        public init(url: String, language: String, format: String, isHardsub: Bool = false) {
            self.url = url
            self.language = language
            self.format = format
            self.isHardsub = isHardsub
        }
    }

    public struct Video: Codable, Sendable {
        public var url: String
        public var quality: String
        @PostcardOptionalMapCoded public var headers: [String: String]?
        public var audioTracks: [AudioTrack]?
        public var subtitles: [Subtitle]?

        public init(
            url: String, quality: String, headers: [String: String]? = nil,
            audioTracks: [AudioTrack]? = nil, subtitles: [Subtitle]? = nil
        ) {
            self.url = url
            self.quality = quality
            self._headers = PostcardOptionalMapCoded(wrappedValue: headers)
            self.audioTracks = audioTracks
            self.subtitles = subtitles
        }
    }

    public struct Season: Codable, Sendable {
        public var key: String
        public var title: String
        public var isCurrent: Bool

        public init(key: String, title: String, isCurrent: Bool = false) {
            self.key = key
            self.title = title
            self.isCurrent = isCurrent
        }
    }

    public var key: String
    public var title: String
    public var studios: [String]?
    public var description: String?
    public var tags: [String]?
    public var cover: String?
    public var url: String?
    public var status: Status
    public var contentRating: ContentRating
    public var nsfw: Int32
    public var episodes: [Episode]?
    public var seasons: [Season]?

    public init(
        key: String, title: String, studios: [String]? = nil, description: String? = nil,
        tags: [String]? = nil, cover: String? = nil, url: String? = nil, status: Status = .Unknown,
        contentRating: ContentRating = .Safe, nsfw: Int32 = 0, episodes: [Episode]? = nil,
        seasons: [Season]? = nil
    ) {
        self.key = key
        self.title = title
        self.studios = studios
        self.description = description
        self.tags = tags
        self.cover = cover
        self.url = url
        self.status = status
        self.contentRating = contentRating
        self.nsfw = nsfw
        self.episodes = episodes
        self.seasons = seasons
    }
}

/// A catalog entry of any kind.
public enum MediaEntry: Codable, Sendable, PostcardEnumMarker {
    case manga(Manga)
    case anime(Anime)
    case novel(Novel)

    enum CodingKeys: Int, CodingKey, PostcardEnumKeys {
        case manga = 0
        case anime = 1
        case novel = 2
    }

    public var kind: MediaKind {
        switch self {
        case .manga: return .manga
        case .anime: return .anime
        case .novel: return .novel
        }
    }

    public var key: String {
        switch self {
        case .manga(let manga): return manga.key
        case .anime(let anime): return anime.key
        case .novel(let novel): return novel.key
        }
    }

    /// How `chapter`, one of this entry's, is read.
    public func contentKind(of chapter: Chapter) -> ContentKind {
        chapter.kind ?? kind.defaultContentKind
    }
}

/// One page of catalog entries; a plugin serving several kinds may mix them.
public struct MediaPageResult: Codable, Sendable {
    public var entries: [MediaEntry]
    public var hasNextPage: Bool

    public init(entries: [MediaEntry], hasNextPage: Bool) {
        self.entries = entries
        self.hasNextPage = hasNextPage
    }
}

public enum HomeComponentValue: Codable, Sendable, PostcardEnumMarker {
    case scroller([Manga], Listing?)
    case mangaList(Bool, Int32?, [Manga], Listing?)
    case mangaChapterList(Int32?, [MangaWithChapter], Listing?)
    case animeScroller([Anime], Listing?)
    case animeList(Bool, Int32?, [Anime], Listing?)
    case animeEpisodeList(Int32?, [AnimeWithEpisode], Listing?)
    case bigScroller([Manga], Float32?)
    case animeBigScroller([Anime], Float32?)
    case novelScroller([Novel], Listing?)
    case novelList(Bool, Int32?, [Novel], Listing?)
    case novelChapterList(Int32?, [NovelWithChapter], Listing?)
    case novelBigScroller([Novel], Float32?)
    case filters([FilterItem])
    case links([Link])
    /// Entries of any kind, from plugins serving several.
    case mediaScroller([MediaEntry], Listing?)
    case mediaList(Bool, Int32?, [MediaEntry], Listing?)
    case mediaBigScroller([MediaEntry], Float32?)

    enum CodingKeys: Int, CodingKey, PostcardEnumKeys {
        case scroller = 0
        case mangaList = 1
        case mangaChapterList = 2
        case animeScroller = 3
        case animeList = 4
        case animeEpisodeList = 5
        case bigScroller = 6
        case animeBigScroller = 7
        case novelScroller = 8
        case novelList = 9
        case novelChapterList = 10
        case novelBigScroller = 11
        case filters = 12
        case links = 13
        case mediaScroller = 14
        case mediaList = 15
        case mediaBigScroller = 16
    }
}

public struct HomeComponent: Codable, Sendable {
    public var title: String?
    public var subtitle: String?
    public var value: HomeComponentValue

    public init(title: String? = nil, subtitle: String? = nil, value: HomeComponentValue) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
    }
}

public struct HomeLayout: Codable, Sendable {
    public var components: [HomeComponent]

    public init(components: [HomeComponent]) {
        self.components = components
    }
}

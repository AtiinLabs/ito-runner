import Foundation

// MARK: - Net Module

public protocol NetModule: Sendable {
    func fetch(request: NetRequest) async throws -> NetResponse
    func fetch(request: NetRequest, options: NetOptions) async throws -> NetResponse
}

public extension NetModule {
    func fetch(request: NetRequest, options: NetOptions) async throws -> NetResponse {
        return try await fetch(request: request)
    }
}

public struct NetOptions: Codable, Sendable {
    public let rateLimit: Int32
    public let persistCookies: Bool

    public init(rateLimit: Int32 = 0, persistCookies: Bool = false) {
        self.rateLimit = rateLimit
        self.persistCookies = persistCookies
    }
}

public struct NetRequest: Codable, Sendable {
    public let url: String
    public let method: String
    @PostcardMapCoded public var headers: [String: String]
    public let body: [UInt8]?

    public init(url: String, method: String, headers: [String: String], body: [UInt8]?) {
        self.url = url
        self.method = method
        self._headers = PostcardMapCoded(wrappedValue: headers)
        self.body = body
    }
}

public struct NetResponse: Codable, Sendable {
    public let status: Int32
    @PostcardMapCoded public var headers: [String: String]
    public let body: [UInt8]

    public init(status: Int32, headers: [String: String], body: [UInt8]) {
        self.status = status
        self._headers = PostcardMapCoded(wrappedValue: headers)
        self.body = body
    }
}

// MARK: - HTML Module

public protocol HtmlModule: Sendable {
    func parse(html: String) throws -> UInt32
    func select(elementId: UInt32, selector: String) throws -> [UInt32]
    func text(elementId: UInt32) throws -> String
    func ownText(elementId: UInt32) throws -> String
    func html(elementId: UInt32) throws -> String
    func outerHtml(elementId: UInt32) throws -> String
    func attr(elementId: UInt32, name: String) throws -> String?
    func free(elementId: UInt32)
    func clear()
}

// MARK: - Std Module

public protocol StdModule: Sendable {
    func print(message: String)
}

// MARK: - Defaults Module

public protocol DefaultsModule: Sendable {
    func set(key: String, value: String)
    func get(key: String) -> String?
    func remove(key: String)
}

// MARK: - Env Module

public protocol EnvModule: Sendable {
    func getLanguages() -> [String]
}

// MARK: - Webview Module

public protocol WebviewModule: Sendable {
    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse
    func executeJs(script: String) async throws -> String
}

public struct WebviewRequest: Codable, Sendable {
    public let url: String
    /// Reserved; hosts ignore it. The SDK always sends nil.
    public let script: String?

    public init(url: String, script: String?) {
        self.url = url
        self.script = script
    }
}

public struct WebviewResponse: Codable, Sendable {
    public let url: String
    public let html: String

    public init(url: String, html: String) {
        self.url = url
        self.html = html
    }
}

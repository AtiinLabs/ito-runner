import Foundation

/// The default implementation of `NetModule` using `URLSession`.
public final class DefaultNetModule: NetModule, @unchecked Sendable {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        guard let url = URL(string: request.url) else {
            throw ItoError.hostModuleError(domain: "net", message: "Invalid URL: \(request.url)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method

        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ItoError.hostModuleError(domain: "net", message: "Not an HTTP response")
            }

            var responseHeaders: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let keyStr = key as? String, let valStr = value as? String {
                    responseHeaders[keyStr] = valStr
                }
            }

            return NetResponse(
                status: Int32(httpResponse.statusCode),
                headers: responseHeaders,
                body: Array(data)
            )
        } catch {
            throw ItoError.hostModuleError(
                domain: "net", message: "Fetch failed: \(error.localizedDescription)")
        }
    }
}

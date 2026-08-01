import Foundation

protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let response = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        guard 200..<300 ~= response.statusCode else {
            let isRateLimited = response.statusCode == 429 ||
                (response.statusCode == 403 && (
                    response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                        response.value(forHTTPHeaderField: "Retry-After") != nil
                ))
            if isRateLimited {
                throw HTTPClientError.rateLimited
            }
            throw HTTPClientError.unacceptableStatus(response.statusCode)
        }

        return (data, response)
    }
}

enum HTTPClientError: Error, Equatable {
    case invalidResponse
    case rateLimited
    case unacceptableStatus(Int)
}

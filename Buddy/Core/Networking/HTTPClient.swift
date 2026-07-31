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
            throw HTTPClientError.unacceptableStatus(response.statusCode)
        }

        return (data, response)
    }
}

enum HTTPClientError: Error, Equatable {
    case invalidResponse
    case unacceptableStatus(Int)
}

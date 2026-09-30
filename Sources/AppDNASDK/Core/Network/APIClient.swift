import Foundation
import Compression
import UIKit

/// URL request errors.
enum APIError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, data: Data?)
    case networkError(Error)
    case decodingError(Error)
    case compressionError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let statusCode, let data):
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
            return "HTTP \(statusCode): \(body)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .compressionError:
            return "Compression error"
        }
    }
}

/// URLSession-based HTTP client with retry and auth headers.
final class APIClient {
    let apiKey: String
    let environment: Environment
    private let session: URLSession
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [1, 2, 4]

    /// HTTP statuses that look like 4xx but must be retried, never latched as permanent.
    static let transientStatusCodes: Set<Int> = [408, 429]

    /// Set to true when event upload gets a *permanent* 4xx (retrying won't help).
    ///
    /// 429 (rate limited) and 408 (request timeout) are explicitly NOT permanent —
    /// they are the expected responses under load, and treating them as permanent
    /// halted all uploads until app restart. Android has always retried them.
    private(set) var eventUploadPermanentlyFailed = false

    /// Seconds the server asked us to wait, parsed from a `Retry-After` header on
    /// the last 429/503. Consumed (and cleared) by `EventQueue` when scheduling its
    /// next attempt. Capped so a hostile or mistaken header cannot park the queue.
    private(set) var retryAfterSeconds: TimeInterval?

    /// Upper bound on an honored `Retry-After`.
    static let maxRetryAfter: TimeInterval = 120

    /// Reads and clears the pending `Retry-After` hint.
    func consumeRetryAfter() -> TimeInterval? {
        defer { retryAfterSeconds = nil }
        return retryAfterSeconds
    }

    /// Parses `Retry-After`, which RFC 9110 allows as either delta-seconds or an
    /// HTTP-date. Returns nil for an absent, unparseable, or non-positive value.
    static func parseRetryAfter(_ raw: String?) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds > 0 ? min(seconds, maxRetryAfter) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        let delta = date.timeIntervalSinceNow
        return delta > 0 ? min(delta, maxRetryAfter) : nil
    }

    init(apiKey: String, environment: Environment) {
        self.apiKey = apiKey
        self.environment = environment

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Execute a request with automatic retry on 5xx and network errors.
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let urlRequest = try buildRequest(for: endpoint)
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = retryDelays[min(attempt - 1, retryDelays.count - 1)]
                Log.debug("Retrying request (attempt \(attempt + 1)) after \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let (data, response) = try await session.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.networkError(URLError(.badServerResponse))
                }

                let statusCode = httpResponse.statusCode

                if (200..<300).contains(statusCode) {
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        return decoded
                    } catch {
                        throw APIError.decodingError(error)
                    }
                }

                // 4xx — client error, no retry
                if (400..<500).contains(statusCode) {
                    throw APIError.httpError(statusCode: statusCode, data: data)
                }

                // 5xx — server error, retry
                lastError = APIError.httpError(statusCode: statusCode, data: data)
                Log.warning("Server error \(statusCode), will retry")
            } catch let error as APIError {
                throw error // Don't retry decoding or 4xx errors
            } catch {
                // Network error — retry
                lastError = APIError.networkError(error)
                Log.warning("Network error: \(error.localizedDescription), will retry")
            }
        }

        throw lastError ?? APIError.networkError(URLError(.unknown))
    }

    /// Fire-and-forget POST with JSON body. Callback with success/error.
    func post(path: String, body: [String: Any], completion: ((Result<Void, Error>) -> Void)? = nil) {
        Task {
            do {
                let request = try postRequest(path: path, body: body)
                let (_, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    completion?(.failure(APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: nil)))
                    return
                }
                completion?(.success(()))
            } catch {
                completion?(.failure(error))
            }
        }
    }

    /// The request `post` sends: the resolved base URL (SPEC-497 §3.11 — the test-only override applies
    /// here exactly as it does to `request` and event ingest), the auth and SDK headers, the JSON body.
    func postRequest(path: String, body: [String: Any]) throws -> URLRequest {
        let base = APIBaseURL.resolve(environment: environment)
        guard let url = URL(string: base + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Round-10 #15 — backend version-gating/attribution keys on these; Android sends both on
        // every request, iOS sent neither, so every iOS call looked like an unknown SDK version.
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Fire-and-forget POST for event batches with gzip compression. Returns success status.
    func sendEvents(_ data: Data) async -> Bool {
        do {
            var urlRequest = try buildRequest(for: .ingestEvents)

            // SPEC-067: Compress event batch for bandwidth reduction
            if let compressed = Self.deflateCompress(data) {
                urlRequest.httpBody = compressed
                urlRequest.setValue("deflate", forHTTPHeaderField: "Content-Encoding")
                Log.debug("Compressed events: \(data.count) → \(compressed.count) bytes (\(String(format: "%.1f", Double(data.count) / max(Double(compressed.count), 1)))x)")
            } else {
                urlRequest.httpBody = data
                Log.warning("Compression failed, sending uncompressed")
            }

            let (responseData, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            let body = String(data: responseData.prefix(500), encoding: .utf8) ?? "no body"
            return applyEventUploadStatus(
                httpResponse.statusCode,
                retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                body: body
            )
        } catch {
            Log.error("Event upload network error: \(error.localizedDescription). Will retry.")
            return false
        }
    }

    /// What an event-upload HTTP status means, independent of any network.
    ///
    /// SPEC-070-B AC-35: a PURE seam. `permanent_4xx_dropped` and `rate_limited_429_retried` assert
    /// this table on iOS and Android against the same fixture, so the two SDKs cannot drift on the
    /// question that caused the live defect — is a 429 permanent? Android says no; iOS used to say
    /// yes, and one rate-limit halted every upload until the app restarted.
    enum EventUploadDisposition {
        /// 2xx — the batch landed. Clears the latch.
        case success
        /// Retry with backoff: 408, 429, every 5xx, and anything else unexpected.
        case retryTransient
        /// A genuine permanent 4xx (400/401/403/404 …). Drop the batch and LATCH: retrying a bad
        /// API key forever would only drain the battery.
        case dropPermanent
    }

    static func disposition(for statusCode: Int) -> EventUploadDisposition {
        if (200..<300).contains(statusCode) { return .success }
        if transientStatusCodes.contains(statusCode) { return .retryTransient }
        if (400..<500).contains(statusCode) { return .dropPermanent }
        // 5xx, and any status nobody expected — the server may recover, so retry.
        return .retryTransient
    }

    /// Apply an event-upload status to `eventUploadPermanentlyFailed` and the `Retry-After` hint.
    ///
    /// Extracted from `sendEvents` for one reason: the latch was UNTESTABLE. It only ever moved
    /// inside an `async` method that performs a real `URLSession` round trip, so no test could ask
    /// the question that matters — *does a 429 leave `eventUploadPermanentlyFailed` false?* — which
    /// is precisely why the answer was "no" in production for as long as it was. This is the seam
    /// AC-35's `permanent_4xx_dropped` fixture drives; it mutates the same flag the network path
    /// mutates, because it IS the network path's body.
    ///
    /// - Returns: true when the batch was accepted.
    @discardableResult
    func applyEventUploadStatus(_ statusCode: Int, retryAfterHeader: String?, body: String = "no body") -> Bool {
        switch Self.disposition(for: statusCode) {
        case .success:
            eventUploadPermanentlyFailed = false
            retryAfterSeconds = nil
            return true

        case .dropPermanent:
            if statusCode == 401 {
                Log.error("Event upload rejected: HTTP 401 — Invalid API key. Check your key in Console → Settings → SDK. Retrying won't help.")
            } else {
                Log.error("Event upload rejected: HTTP \(statusCode) — \(body). Retrying won't help.")
            }
            eventUploadPermanentlyFailed = true
            return false

        case .retryTransient:
            // 429 rate-limited / 408 request-timeout are transient by definition, and 503 commonly
            // sends a Retry-After. Honor it in both cases. The latch is deliberately NOT touched:
            // a transient failure must not clear a latch a permanent one set, and must never set one.
            retryAfterSeconds = Self.parseRetryAfter(retryAfterHeader)
            let hint = retryAfterSeconds.map { " Retry-After: \($0)s." } ?? ""
            if Self.transientStatusCodes.contains(statusCode) {
                Log.warning("Event upload throttled: HTTP \(statusCode).\(hint) Will retry.")
            } else {
                Log.warning("Event upload failed: HTTP \(statusCode) — \(body).\(hint) Will retry.")
            }
            return false
        }
    }

    // MARK: - User Agent

    /// Cached user agent string using ProcessInfo to avoid MainActor-isolated UIDevice access.
    private static let userAgent: String = {
        let sdkVersion = AppDNA.sdkVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        return "AppDNASDK/\(sdkVersion) iOS/\(osVersionString)"
    }()

    private func buildRequest(for endpoint: Endpoint) throws -> URLRequest {
        guard let url = endpoint.url(environment: environment) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Round-10 #15 — SDK identity headers (parity with Android's SdkIdentityInterceptor).
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")
        // SPEC-067: Request compressed responses from server
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")

        if endpoint.method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Serialize body from endpoint if present
        if let body = endpoint.body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return request
    }

    // MARK: - SPEC-067: Deflate Compression

    /// Compress data using raw deflate via Apple's Compression framework (no zlib dependency).
    static func deflateCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // Allocate a destination buffer (worst case: slightly larger than input)
        let destinationSize = data.count + 64
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourceRaw -> Int in
            guard let sourcePtr = sourceRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_encode_buffer(
                destinationBuffer, destinationSize,
                sourcePtr, data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }
}

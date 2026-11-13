import Foundation
import Compression
import UIKit

/// URL request errors.
enum APIError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, data: Data?)
    /// HTTP 429 from `requestData`, with the server's `Retry-After` (parsed and capped by
    /// `APIClient.parseRetryAfter`; nil when absent or unreadable).
    case rateLimited(retryAfter: TimeInterval?, data: Data?)
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
        case .rateLimited(let retryAfter, let data):
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
            return "HTTP 429: \(body)\(retryAfter.map { " (Retry-After: \($0)s)" } ?? "")"
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
    /// Test seam: replaces `retryDelays` for `requestData` (nil in production).
    static var requestRetryDelaysForTesting: [TimeInterval]?

    /// HTTP statuses that look like 4xx but must be retried, never latched as permanent.
    static let transientStatusCodes: Set<Int> = [408, 429]

    /// Set to true when the server refuses an event batch's content (retrying won't help).
    ///
    /// 429 (rate limited) and 408 (request timeout) are explicitly NOT permanent —
    /// they are the expected responses under load, and treating them as permanent
    /// halted all uploads until app restart. Android has always retried them.
    private(set) var eventUploadPermanentlyFailed = false

    /// Whether the LAST event upload's batch was refused for its content (`EventUploadDisposition.dropPermanent`) —
    /// per request, unlike the `eventUploadPermanentlyFailed` latch, which a transient failure leaves set. An upload
    /// owner drops the batch it just sent only on this: a network error, a 401 or a proxy's page must not drop a
    /// batch the server never judged.
    private(set) var lastEventUploadRejectedPermanently = false

    /// Whether the LAST event upload's answer pauses uploads (`rejectionPausesUploads`) — per request. The batch is
    /// kept: a 401 / 403 is never a refusal of the batch.
    private(set) var lastEventUploadRejectionPausesUploads = false

    /// Whether a refused event upload with this status pauses every upload path until the next foreground or
    /// `AppDNA.flush()`: 401 / 403 — the API key is wrong or revoked (or a tunnel or proxy refuses the device), so
    /// every later batch would be refused the same way, and retrying on a timer only drains the battery. The batch is
    /// KEPT (`eventUploadDisposition(for:body:)` retries a 401 / 403) and sent once uploads resume. The in-process
    /// queue and the background uploader both apply it; Android `ApiClient.rejectionPausesUploads`, same table
    /// (fixture `permanent_4xx_dropped`, `rejection_runs`).
    static func rejectionPausesUploads(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    /// The statuses with which the ingest route refuses a batch's CONTENT: 400 (the body is not valid JSON, or fails
    /// the batch schema), 413 (too large, or a compressed body that does not decode) and 422 (reserved for a content
    /// refusal; the route does not answer it today). A batch is dropped only on one of these, and only when the body
    /// is the route's own error (`isIngestErrorBody`).
    static let batchRejectionStatusCodes: Set<Int> = [400, 413, 422]

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

        self.session = URLSession(configuration: Self.sessionConfiguration())
    }

    /// The SDK's session: 30 s per request, 60 s per resource, and NO HTTP cache.
    ///
    /// Every answer the SDK reads from its own API has to be the server's answer now: the bootstrap
    /// (`runtime_lock`, geo, map keys), `/billing/entitlements`, option-set pages. The default
    /// configuration used `URLCache.shared` with the protocol cache policy, and the bootstrap was sent
    /// with `Cache-Control: private, max-age=86400` — so for 24 hours after one successful bootstrap,
    /// every later one (each launch, each re-configure) was answered from the cache without reaching
    /// the server, online or offline: a runtime lock set in that window did not reach the device.
    /// With no cache, an unreachable server is a failed bootstrap (degraded mode), the same as Android,
    /// whose OkHttp client has no cache.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    /// Execute a request with automatic retry on 5xx and network errors.
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let data = try await requestData(endpoint)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// The raw 2xx body of `endpoint`, with the retry rules of `request(_:)` (5xx and network errors
    /// retried, a 4xx thrown at once as `APIError.httpError`). `request(_:)` decodes this.
    func requestData(_ endpoint: Endpoint) async throws -> Data {
        let urlRequest = try buildRequest(for: endpoint)
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delays = Self.requestRetryDelaysForTesting ?? retryDelays
                let delay = delays[min(attempt - 1, delays.count - 1)]
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
                    return data
                }

                // 4xx — client error, no retry. A 429 carries the server's Retry-After to the caller.
                if statusCode == 429 {
                    throw APIError.rateLimited(
                        retryAfter: Self.parseRetryAfter(httpResponse.value(forHTTPHeaderField: "Retry-After")),
                        data: data)
                }
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

    /// The request `post` sends: the resolved base URL (the test-only override applies
    /// here exactly as it does to `request` and event ingest), the auth and SDK headers, the JSON body.
    func postRequest(path: String, body: [String: Any]) throws -> URLRequest {
        let base = APIBaseURL.resolve(environment: environment)
        guard let url = URL(string: base + path) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Backend version-gating/attribution keys on these; Android sends both on
        // every request, iOS sent neither, so every iOS call looked like an unknown SDK version.
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// the consent signal (`POST /api/v1/ingest/consent`), ONE network attempt (URLSession never
    /// re-sends a POST on its own). The sender owns the retry policy (the consent state table). Classified by
    /// `disposition(for:)`, the same table the event upload uses (`permanent_4xx_dropped`).
    func postConsentOnce(body: [String: Any]) async -> ConsentPostOutcome {
        do {
            let request = try postRequest(path: ConsentSignalSender.path, body: body)
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transient(retryAfterSeconds: nil) }
            switch Self.disposition(for: http.statusCode) {
            case .success:
                return .success
            case .dropPermanent:
                Log.warning("Consent signal rejected (HTTP \(http.statusCode)): dropped until the next launch.")
                return .drop
            case .retryTransient:
                let ra = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")).map { Int64($0.rounded(.up)) }
                return .transient(retryAfterSeconds: ra)
            }
        } catch {
            Log.warning("Consent signal network error: \(error.localizedDescription)")
            return .transient(retryAfterSeconds: nil)
        }
    }

    /// Fire-and-forget POST for event batches with gzip compression. Returns success status.
    func sendEvents(_ data: Data) async -> Bool {
        lastEventUploadRejectedPermanently = false
        lastEventUploadRejectionPausesUploads = false
        do {
            var urlRequest = try buildRequest(for: .ingestEvents)

            // Compress event batch for bandwidth reduction
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
            return applyEventUploadStatus(
                httpResponse.statusCode,
                retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                body: responseData
            )
        } catch {
            Log.error("Event upload network error: \(error.localizedDescription). Will retry.")
            return false
        }
    }

    /// What an upload's HTTP answer means, independent of any network.
    ///
    /// A PURE seam. `permanent_4xx_dropped` and `rate_limited_429_retried` assert
    /// this table on iOS and Android against the same fixture, so the two SDKs cannot drift on the
    /// question that caused the live defect — is a 429 permanent? Android says no; iOS used to say
    /// yes, and one rate-limit halted every upload until the app restarted.
    enum EventUploadDisposition {
        /// 2xx — the batch landed. Clears the latch.
        case success
        /// Keep the batch and retry: 401, 403, 404, 408, 409, 429, every 5xx, and any answer that is not the ingest
        /// route's refusal of the batch.
        case retryTransient
        /// The server refused this batch's content (400 / 413 / 422 in the ingest route's error shape). Drop the
        /// batch, counted, and LATCH.
        case dropPermanent
    }

    /// What an event-upload answer means. The pure classifier the shared `permanent_4xx_dropped` fixture asserts on
    /// both platforms; Android `ApiClient.eventUploadDispositionFor`, same table.
    ///
    /// - 2xx → `.success`.
    /// - 400 / 413 / 422 whose body is the ingest route's error → `.dropPermanent`: the server judged this batch,
    ///   and sending it again would be refused the same way.
    /// - anything else → `.retryTransient`, the batch kept: 401 / 403 (a key problem — every batch would be refused
    ///   alike, so uploads pause, see `rejectionPausesUploads`), 404 (a wrong route or base URL), 408, 409, 429,
    ///   5xx, and every status whose body is not the route's — a tunnel, captive portal, proxy or load-balancer page.
    ///   None of those says anything about the batch, and each used to delete it.
    static func eventUploadDisposition(for statusCode: Int, body: Data) -> EventUploadDisposition {
        if (200..<300).contains(statusCode) { return .success }
        if batchRejectionStatusCodes.contains(statusCode) && isIngestErrorBody(body) { return .dropPermanent }
        return .retryTransient
    }

    /// Whether a body is the error the ingest route answers with (`withErrorHandler`):
    /// `{"error":{"code":"<non-empty string>","message":"<string>", …}}`. An HTML page, an empty body, `{}`, a string
    /// `error`, or JSON of any other shape is not.
    static func isIngestErrorBody(_ body: Data) -> Bool {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let code = error["code"] as? String, !code.isEmpty,
              error["message"] is String
        else { return false }
        return true
    }

    /// The STATUS-ONLY table the consent signal (`postConsentOnce`) uses. Event uploads do not: they use
    /// `eventUploadDisposition(for:body:)`, which also reads the body, because an event batch is data the device
    /// holds and dropping it on a status that is not about it loses that data for good.
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
    /// The `permanent_4xx_dropped` fixture drives; it mutates the same flag the network path
    /// mutates, because it IS the network path's body.
    ///
    /// - Returns: true when the batch was accepted.
    @discardableResult
    func applyEventUploadStatus(_ statusCode: Int, retryAfterHeader: String?, body: Data = Data()) -> Bool {
        let disposition = Self.eventUploadDisposition(for: statusCode, body: body)
        lastEventUploadRejectedPermanently = disposition == .dropPermanent
        lastEventUploadRejectionPausesUploads = disposition == .retryTransient && Self.rejectionPausesUploads(statusCode)
        let bodyText = String(data: body.prefix(500), encoding: .utf8) ?? "no body"
        switch disposition {
        case .success:
            eventUploadPermanentlyFailed = false
            retryAfterSeconds = nil
            return true

        case .dropPermanent:
            Log.error("Event upload refused: HTTP \(statusCode) — the server refused this batch's content: \(bodyText). Retrying won't help.")
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
            } else if lastEventUploadRejectionPausesUploads {
                Log.error("Event upload refused: HTTP \(statusCode) — check your key in Console → Settings → SDK, or a proxy in the way. The events are kept and sent once uploads are accepted again.")
            } else {
                Log.warning("Event upload failed: HTTP \(statusCode) — \(bodyText).\(hint) Events kept; will retry.")
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
        // SDK identity headers (parity with Android's SdkIdentityInterceptor).
        request.setValue(AppDNA.sdkVersion, forHTTPHeaderField: "x-sdk-version")
        request.setValue("ios", forHTTPHeaderField: "x-sdk-platform")
        /*
         * `gzip` ONLY. We must not advertise an encoding we cannot decode.
         *
         * This said `gzip, deflate`, mirroring Android, where the same line was worse than useless:
         * setting `Accept-Encoding` by hand stops OkHttp decompressing at all, so every gzip answer
         * arrived as raw bytes. URLSession does NOT share that behaviour — measured on the simulator
         * against a loopback server serving a real gzip member, a hand-set header and all: the body
         * parses (`GzipResponseDecodingTests.testAGzipAnswerIsDecoded`). So gzip on iOS was never
         * broken.
         *
         * `deflate` was, latently. Nothing in URLSession decodes a RAW deflate body, so a server
         * taking us at our word would send an encoding this client cannot read — the same silent
         * "bootstrap failed, using cached config" ending Android had, waiting for a server that
         * prefers deflate. Offering only what we decode removes the trap without changing anything
         * that works today.
         */
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        if endpoint.method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Serialize body from endpoint if present
        if let body = endpoint.body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        return request
    }

    // MARK: - Deflate Compression

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

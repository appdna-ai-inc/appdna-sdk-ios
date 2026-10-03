import Foundation

/// The one resolver for the API / event-ingest base URL.
///
/// TEST-ONLY override: the Info.plist key `AppDNABaseURLOverride` is honoured only when the SDK is
/// configured with `.sandbox` AND the build is not from the App Store (simulator, a sandbox receipt —
/// which includes TestFlight — or an embedded provisioning profile). Everything else gets
/// `https://api.appdna.ai`. The override covers the API and event ingest only (not Firestore, not
/// CDN assets). Not public, not documented.
enum APIBaseURL {
    static let production = "https://api.appdna.ai"
    static let infoPlistKey = "AppDNABaseURLOverride"

    /// Test seams: replace the Info.plist read and the App-Store gate.
    static var infoPlistReaderForTesting: ((String) -> Any?)?
    static var gateForTesting: (() -> Bool)?

    private static let logLock = NSLock()
    private static var loggedInvalid: Set<String> = []

    /// The base URL for `environment`, reading the override from `bundle`.
    static func resolve(
        environment: Environment,
        bundle: Bundle = .main,
        gate: (() -> Bool)? = nil
    ) -> String {
        let raw = infoPlistReaderForTesting.map { $0(infoPlistKey) } ?? bundle.object(forInfoDictionaryKey: infoPlistKey)
        let gateOpen = (gate ?? gateForTesting ?? { isNonAppStoreBuild(bundle: bundle) })()
        return resolve(environment: environment, overrideValue: raw, gateOpen: gateOpen)
    }

    /// Pure decision.
    static func resolve(environment: Environment, overrideValue: Any?, gateOpen: Bool) -> String {
        guard environment == .sandbox, gateOpen, let value = validatedOverride(overrideValue) else {
            return production
        }
        return value
    }

    /// Blank / whitespace → absent; must be an `http(s)` URL with a host (else logged once and
    /// ignored); a trailing `/` is stripped.
    static func validatedOverride(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            logInvalidOnce(s)
            return nil
        }
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    private static func logInvalidOnce(_ value: String) {
        logLock.lock()
        let first = loggedInvalid.insert(value).inserted
        logLock.unlock()
        if first { Log.warning("\(infoPlistKey) ignored: not an http(s) URL with a host") }
    }

    /// True for any build that is not from the App Store.
    static func isNonAppStoreBuild(bundle: Bundle = .main) -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        if bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return true }
        if bundle == .main { return mainBundleHasProvisioningProfile }
        return bundle.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
    }

    /// The main bundle's `embedded.mobileprovision` never changes while the process runs — looked up
    /// once, not on every request.
    private static let mainBundleHasProvisioningProfile: Bool =
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
}

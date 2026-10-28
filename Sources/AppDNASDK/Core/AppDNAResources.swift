import Foundation

/// The SDK's own resource bundle, under either package manager.
///
/// SwiftPM generates `Bundle.module` for a target with resources; CocoaPods does not, and builds the
/// `resource_bundles` entry of the podspec into an `AppDNASDK.bundle` inside the framework instead. Reading
/// `Bundle.module` directly does not compile as a pod — every Flutter and React Native iOS host is a pod — so
/// every resource lookup goes through here.
enum AppDNAResources {
    static let bundle: Bundle? = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let framework = Bundle(for: AppDNAResourcesToken.self)
        guard let url = framework.url(forResource: "AppDNASDK", withExtension: "bundle") else { return nil }
        return Bundle(url: url)
        #endif
    }()
}

private final class AppDNAResourcesToken {}

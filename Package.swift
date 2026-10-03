// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppDNASDK",
    platforms: [.iOS(.v16)],
    products: [
        // The product carries the ObjC `AppDNASDKLoader` target (the `+load` launch hook
        // that installs the notification proxy). Consumers' `Package.swift` lines are unchanged.
        .library(name: "AppDNASDK", targets: ["AppDNASDK", "AppDNASDKLoader"]),
        // The extension-safe Notification Service Extension helper (`NotificationService` + the push
        // action-button categories). No dependencies and no app-only API, so a Notification Service
        // Extension links it alone; AppDNASDK depends on it, so the app and the extension register
        // button categories through the same code.
        .library(name: "AppDNANotificationExtension", targets: ["AppDNANotificationExtension"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
        // SPEC-070-0 §3.4 — visual snapshot harness (iOS leg).
        // PNG goldens live in Tests/__Snapshots__/ and are committed; reviewed during PR.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        // SPEC-495 — the bundled interactive map tier (Google).
        //
        // 🔴 9.4.0, AND THE VERSION IS THE WHOLE FIX. 8.4.0 publishes FOUR products
        // (GoogleMaps / Base / Core / M4B), each a `GMSEmpty.m` shim that says `@import GoogleMaps;`
        // while depending only on its own binary. As a transitive SwiftPM dependency that cannot be
        // built reliably in either direction: linking the one product fails with
        // "Module 'GoogleMapsBase' not found", and linking all three fails with the mirror image,
        // "Module 'GoogleMaps' not found", in the Base and Core shims. A warm module cache hides it
        // — the Mac bridge went green on a second build and CI, which is always cold, did not.
        // 9.x collapses it to ONE product and one binary target. 9.4.0 rather than the newest
        // (11.2.0) because CocoaPods only publishes GoogleMaps up to 9.4.0: pinning SPM higher would
        // ship a DIFFERENT MAJOR VERSION to SPM consumers than to CocoaPods ones — and the wrappers
        // are CocoaPods consumers, so the platform this whole spec is for would be the one running
        // the version nothing was tested against.
        .package(url: "https://github.com/googlemaps/ios-maps-sdk.git", from: "9.4.0"),
        // Optional billing providers — a SOURCE build only. Uncomment the dependency, add its product to
        // the AppDNASDK target, AND add `swiftSettings: [.define("APPDNA_LINK_REVENUECAT")]` (Adapty:
        // `APPDNA_LINK_ADAPTY`). The bridge needs the define: a host app that adds the provider's package
        // can make the module importable inside AppDNASDK by build order alone, and that must not switch
        // the SDK into buying through the provider (`BillingOwnership.isLinked`).
        // .package(url: "https://github.com/adaptyteam/AdaptySDK-iOS.git", from: "3.17.3"),
        // .package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "AppDNASDK",
            dependencies: [
                "AppDNANotificationExtension",
                "KeychainAccess",
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                // One product, because 9.x publishes exactly one. See the note above the
                // dependency: the three-product spelling this replaced was a workaround for 8.4.0's
                // split package, and it only ever built against a warm module cache.
                .product(name: "GoogleMaps", package: "ios-maps-sdk"),
            ],
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .target(
            name: "AppDNANotificationExtension",
            // Application-extension-only API: an extension target compiles it with
            // APPLICATION_EXTENSION_API_ONLY. (Not an `unsafeFlags` setting — SwiftPM refuses a remote
            // package that uses one; `scripts/__tests__/ios-notification-extension-safe.test.ts`
            // keeps app-only API out of it.)
            path: "Sources/AppDNANotificationExtension",
            // An extension that links only this module ships only this manifest (it uses UserDefaults).
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        // A `.m` only, NO public header, so nothing here is exposed to Swift hosts.
        // `publicHeadersPath` is omitted, so SwiftPM uses the default `include/` — and SwiftPM (Xcode
        // 26) REFUSES to resolve the package when that directory is missing ("public headers
        // ("include") directory path … is invalid"), so an empty `include/` is committed with a
        // `.gitkeep` (hidden files are ignored by SwiftPM and by the podspec's `*.m` glob).
        .target(
            name: "AppDNASDKLoader",
            path: "Sources/AppDNASDKLoader"
        ),
        .testTarget(
            name: "AppDNASDKTests",
            dependencies: [
                "AppDNASDK",
                "AppDNANotificationExtension",
                // Linked so the tests can prove the real loader class is present.
                "AppDNASDKLoader",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                // SPEC-495 — the test target links GoogleMaps directly so the interactive-tier proof
                // can hold a real `GMSMapView` and assert on it. `AppDNASDK` linking it is not
                // enough: a Swift module does not re-export its dependencies, so without this the
                // test cannot `import GoogleMaps` and the only thing left to check would be that
                // our own code did not throw — which is exactly the kind of proof #671 slipped past.
                .product(name: "GoogleMaps", package: "ios-maps-sdk"),
            ],
            // The StoreKit test configuration the SKTestSession tests load
            // (`Bundle.module`): coins (consumable), lifetime (non-consumable), and three monthly
            // subscriptions each in its own group (no offer, free-trial intro, pay-up-front intro).
            resources: [.copy("AppDNATestProducts.storekit")]
        )
    ]
)

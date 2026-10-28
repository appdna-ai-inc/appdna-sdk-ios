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
        // Visual snapshot harness (iOS leg).
        // PNG goldens live in Tests/__Snapshots__/ and are committed; reviewed during PR.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        // The bundled interactive map tier (Google).
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
        /*
         * #982 — THE ANIMATION ENGINES, and they are a deliberate cost.
         *
         * `LottieBlockView` and `RiveBlockView` were PLACEHOLDERS — a rounded panel with a play
         * glyph and the filename — for as long as the block types have existed, while Android
         * rendered both for real. 27 blocks across 19 flows on dev used them, 3 of those flows
         * ACTIVE, so real users were looking at a debug box with our text in it.
         *
         * 🔴 The owner's call (2026-10-19) was to ship the engines IN the SDK rather than behind a
         * `#if canImport` the host opts into: roughly 2–3 MB for Lottie and 1–2 MB for Rive in
         * EVERY integrating app, used or not. That was the argument against it and it was taken
         * anyway — so the binary-size question is settled, not open.
         *
         * 🔴 The versions are pinned to the SAME MAJOR the podspec pins, for the reason the
         * GoogleMaps note above spells out: a wrapper host consumes this SDK through CocoaPods, so
         * a channel carrying a different major ships untested code to the platform the wrappers
         * run on. Lottie 4.6.1 is the current release on both. Rive 6.x is current on both, and
         * `riveRenderer` is 6.0's default — 5.x's `skiaRenderer` is gone.
         */
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.6.1"),
        .package(url: "https://github.com/rive-app/rive-ios.git", from: "6.0.0"),
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
                // #982 — the real renderers behind `LottieBlockView` / `RiveBlockView`.
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "RiveRuntime", package: "rive-ios"),
            ],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
                /*
                 * #1003 — Google's official "G" for Sign in with Google buttons, UNMODIFIED.
                 *
                 * The provider glyph was a `Text("G")` in a rounded bold font on both platforms —
                 * a letter, not the mark — so a sign-in button could not be made to match Google's
                 * own branding guidelines, which require the official asset. `.copy`, not
                 * `.process`, so Xcode's asset pipeline cannot re-encode what ships.
                 *
                 * Provenance and terms: `Resources/appdna_google_g.png.LICENSE`.
                 */
                .copy("Resources/appdna_google_g.png"),
                /*
                 * Google's "Google Maps" attribution logo, UNMODIFIED, in the four variants Google
                 * publishes: plain gray (light surfaces), plain white (dark surfaces), and the two
                 * outlined variants for busy backgrounds. A location dropdown listing Google
                 * suggestions draws one under the rows, and a field holding a Google answer keeps one
                 * beside it, because Google's terms require attribution wherever its data is shown
                 * without a Google map. `.copy` for the same reason as the "G" above.
                 *
                 * Provenance and terms: `NOTICE.md`, "Google Maps attribution logo".
                 */
                .copy("Resources/appdna_google_maps_logo_gray.png"),
                .copy("Resources/appdna_google_maps_logo_white.png"),
                .copy("Resources/appdna_google_maps_logo_light_outline.png"),
                .copy("Resources/appdna_google_maps_logo_dark_outline.png")
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
                // The test target links GoogleMaps directly so the interactive-tier proof
                // can hold a real `GMSMapView` and assert on it. `AppDNASDK` linking it is not
                // enough: a Swift module does not re-export its dependencies, so without this the
                // test cannot `import GoogleMaps` and the only thing left to check would be that
                // our own code did not throw — which is exactly the kind of proof #671 slipped past.
                .product(name: "GoogleMaps", package: "ios-maps-sdk"),
            ],
            // The StoreKit test configuration the SKTestSession tests load
            // (`Bundle.module`): coins (consumable), lifetime (non-consumable), and three monthly
            // subscriptions each in its own group (no offer, free-trial intro, pay-up-front intro).
            resources: [
                .copy("AppDNATestProducts.storekit"),
                // #982 — a minimal, valid Lottie (one dark square translating left→right over 30
                // frames) so a render test can prove the engine DRAWS, rather than that it links.
                .copy("LottieProbe.json"),
                /*
                 * #990 — a real `.riv`, because nothing else can prove the Rive engine draws.
                 *
                 * Both SDKs fetch a `.riv` over the network and there is no bundled-asset rung on
                 * that path, so an offline render test needs a file in the bundle. This one is
                 * `teststatemachine.riv` from the rive-ios package's own Example-iOS assets (MIT,
                 * © 2020 Rive — see `RiveStateMachineProbe.riv.LICENSE`), 399 bytes, and it carries
                 * a STATE MACHINE so the same test can exercise `rive_state_machine`.
                 */
                .copy("RiveStateMachineProbe.riv"),
                .copy("RiveStateMachineProbe.riv.LICENSE"),
            ]
        )
    ]
)

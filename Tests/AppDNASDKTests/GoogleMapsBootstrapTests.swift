import XCTest
@testable import AppDNASDK

/// #671 on CocoaPods hosts — the precheck that stands between an onboarding map and a
/// `GMSServicesException` must accept exactly the layouts the Maps SDK searches.
///
/// The rule was measured on GoogleMaps 9.4.0 (a minimal simulator app, one install per layout):
/// top-level `GoogleMaps.bundle` and `<any>.bundle/GoogleMaps.bundle` are found; two levels deep and
/// absent raise at `GMSMapView` init. See `GoogleMapsBootstrap.mapsBundleIsPresent`.
final class GoogleMapsBootstrapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maps-bootstrap-\(UUID().uuidString)")
            .appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private var present: Bool { GoogleMapsBootstrap.mapsBundleIsPresent(inAppBundleAt: root) }

    func testTopLevelBundleIsAccepted() throws {
        try mkdir("GoogleMaps.bundle")
        XCTAssertTrue(present)
    }

    func testCocoaPodsNestedLayoutIsAccepted() throws {
        // GoogleMaps 9.x podspec: resource_bundles { GoogleMapsResources => … } — what every Flutter,
        // React Native and CocoaPods-native host gets. The Maps SDK finds it (measured).
        try mkdir("GoogleMapsResources.bundle/GoogleMaps.bundle")
        XCTAssertTrue(present)
    }

    func testSwiftPMNestedLayoutIsAccepted() throws {
        // One level inside a top-level resource bundle, like CocoaPods — also found (measured).
        try mkdir("GoogleMaps_GoogleMapsTarget.bundle/GoogleMaps.bundle")
        XCTAssertTrue(present)
    }

    func testTwoLevelsDeepIsRejected() throws {
        // The Maps SDK does NOT search here — accepting it would let GMSMapView init raise.
        try mkdir("Outer.bundle/Inner.bundle/GoogleMaps.bundle")
        XCTAssertFalse(present)
    }

    func testInsideAFrameworkIsRejected() throws {
        try mkdir("Frameworks/Foo.framework/GoogleMaps.bundle")
        XCTAssertFalse(present)
    }

    func testNoneIsRejected() throws {
        try mkdir("Other.bundle")
        XCTAssertFalse(present)
    }

    func testAFileNamedLikeTheBundleIsRejected() throws {
        FileManager.default.createFile(atPath: root.appendingPathComponent("GoogleMaps.bundle").path, contents: Data())
        XCTAssertFalse(present)
    }
}

import XCTest
@testable import AppDNASDK

/// `onScreenAction` returns Bool and a `false` reply must BLOCK the action. The
/// action's only escape to the OS is `ScreenManager.urlOpener`; before it was injectable, a veto that
/// silently opened the URL anyway was invisible outside a device.
final class ScreenActionVetoTests: XCTestCase {

    private var host: RecordingScreenDelegate?

    override func tearDown() {
        AppDNA.screenDelegate = nil
        AppDNA.asyncOnScreenAction = nil
        host = nil
        super.tearDown()
    }

    func testVetoedActionOpensNothing() {
        let host = RecordingScreenDelegate(allow: false)
        self.host = host
        AppDNA.screenDelegate = host

        let manager = ScreenManager()
        var opened: [URL] = []
        manager.urlOpener = { opened.append($0) }

        manager.handleAction(
            .openURL(url: "https://example.com"),
            screenId: "screen_1",
            startTime: Date(),
            completion: nil
        )
        // The allow-path dispatches to the main queue; give it a turn so "nothing opened" means the
        // veto blocked it, not that we asserted too early.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(host.seenScreenIds, ["screen_1"])
        XCTAssertTrue(opened.isEmpty)
    }

    func testAllowedActionOpensURL() {
        let host = RecordingScreenDelegate(allow: true)
        self.host = host
        AppDNA.screenDelegate = host

        let manager = ScreenManager()
        let opened = expectation(description: "url opened")
        var openedURLs: [URL] = []
        manager.urlOpener = { url in
            openedURLs.append(url)
            opened.fulfill()
        }

        manager.handleAction(
            .openURL(url: "https://example.com"),
            screenId: "screen_1",
            startTime: Date(),
            completion: nil
        )

        wait(for: [opened], timeout: 1.0)
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://example.com"])
    }

    /// The URL still goes through `URLSafety` — a veto seam must not become a bypass.
    func testUnsafeSchemeIsNeverOpened() {
        let host = RecordingScreenDelegate(allow: true)
        self.host = host
        AppDNA.screenDelegate = host

        let manager = ScreenManager()
        var opened: [URL] = []
        manager.urlOpener = { opened.append($0) }

        manager.handleAction(
            .openURL(url: "javascript:alert(1)"),
            screenId: "screen_1",
            startTime: Date(),
            completion: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(opened.isEmpty)
    }
}

private final class RecordingScreenDelegate: AppDNAScreenDelegate {
    private let allow: Bool
    private(set) var seenScreenIds: [String] = []

    init(allow: Bool) { self.allow = allow }

    func onScreenAction(screenId: String, action: SectionAction) -> Bool {
        seenScreenIds.append(screenId)
        return allow
    }
}

// PaywallErrorBannerBlocksCtaUITests.swift — #1072
//
// AFTER A PURCHASE FAILS, CAN THE USER STILL TAP BUY?
//
// 🔴 #1072 is "one purchase in seven records no StoreKit transaction at all, with no sign of why",
// and the "no sign of why" is the clue: a SwiftUI `Button` that never receives a touch runs no
// action, so it logs nothing, emits nothing, and calls no delegate. Everything inside
// `handleCTATap` — including #1074's `onAction?(.ctaTapped)`, which fires BEFORE the guards — is
// unreachable. From outside, that is indistinguishable from a store that refused.
//
// Three candidates were eliminated by measurement first: the resolution path is id-based end to end,
// `isPurchasing` is reset on every exit from `handlePurchase`, and the plan rows are hittable at 9 of
// 9 positions. The drift mechanism behind #1081 cannot reach the CTA either — `PaywallRenderer`
// excludes `cta` from the ScrollView (`section.type != "cta"`), so it is always pinned outside it.
//
// What is left is something COVERING the pinned CTA, and there is a specific candidate. The
// post-purchase error banner is pinned with a HARDCODED `.padding(.bottom, 80)` while the renderer
// separately MEASURES the pinned group as `pinnedZoneHeight` and uses that measurement only to
// decide overflow. Any paywall whose pinned zone is taller than 80 points — a CTA plus a restore
// link plus legal text, or a section authored `zone: "bottom"`, which #884 made possible for ANY
// section — has its CTA underneath that banner. The banner has an opaque red background, so it is
// hit-testable, and when `errorAllowRetry` is set it stays up until the user finds the Retry button.
//
// So: fail a purchase on purpose, then ask whether the user can buy. That is the real path, and it
// is ~1 in 7 if roughly 1 in 7 purchases is cancelled or refused first.
import XCTest
import StoreKitTest

final class PaywallErrorBannerBlocksCtaUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }
    private var paywallId: String? { TestCredentials.paywallId.isEmpty ? nil : TestCredentials.paywallId }

    private static let monthlyPrice = "4.49"

    @available(iOS 17.0, *)
    func testTheCtaIsStillUsableAfterAPurchaseFails() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        app.launchArguments = [
            "-appdnaApiKey", apiKey,
            "-appdnaPaywall", paywallId,
            "-appdnaProbeStore", "premium_monthly,premium_annual",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))

        let probe = app.staticTexts["host.storeProducts"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        let sawBoth = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "store:2"),
            object: probe,
        )
        try XCTSkipIf(
            XCTWaiter().wait(for: [sawBoth], timeout: 25) != .completed,
            "the session served fewer than both products (probe said \(probe.label))",
        )

        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        var row: XCUIElement?
        for _ in 0..<12 where row == nil {
            if open.isHittable { open.tap() }
            let b = app.buttons
                .containing(NSPredicate(format: "label CONTAINS[c] %@", Self.monthlyPrice))
                .firstMatch
            row = b.waitForExistence(timeout: 5) ? b : nil
        }
        XCTAssertNotNil(row, "no plan row drew at the monthly price")

        let cta = ctaButton(app)
        let before = try XCTUnwrap(cta, "no CTA button was found on the paywall")
        NSLog("[#1072] before any purchase: cta '\(before.label)' frame=\(before.frame) "
            + "enabled=\(before.isEnabled) hittable=\(before.isHittable)")

        /*
         🔴 THE FAILURE IS FORCED, because waiting for one is what made #1072 unreproducible for
         weeks. `failTransactionsEnabled` makes StoreKit refuse the next purchase, which is the state
         a user reaches by cancelling the sheet or having a card declined — the common case, not an
         exotic one.
        */
        session.failTransactionsEnabled = true
        before.tap()
        NSLog("[#1072] first CTA tap sent, with the store set to refuse")

        // Give the refusal time to land and the banner time to animate in.
        _ = waitUntil(timeout: 10) { self.bannerIsUp(app) }
        let bannerUp = bannerIsUp(app)
        NSLog("[#1072] after the refusal: banner up=\(bannerUp)")

        session.failTransactionsEnabled = false

        /*
         The claim: a user whose purchase just failed can try again. Whatever the paywall chose to
         show them, the button that buys must still be reachable — and the geometry is logged either
         way so a failure names WHY rather than only that.
        */
        let after = try XCTUnwrap(ctaButton(app), "the CTA button vanished after the failed purchase")
        NSLog("[#1072] after the refusal: cta '\(after.label)' frame=\(after.frame) "
            + "enabled=\(after.isEnabled) hittable=\(after.isHittable)")
        if let banner = bannerElement(app) {
            NSLog("[#1072] the error banner's frame=\(banner.frame) — overlaps the CTA: "
                + "\(banner.frame.intersects(after.frame))")
        }

        XCTAssertTrue(
            after.isEnabled,
            "the CTA is DISABLED after a failed purchase, so the user cannot retry — `isPurchasing` "
                + "was left set (this is the half #1072 ruled out by reading; a failure here means "
                + "the reading was wrong)",
        )
        XCTAssertTrue(
            after.isHittable,
            "the CTA is not hittable after a failed purchase — something is covering the pinned "
                + "button that buys, which is #1072 reproduced: a tap there reaches no action, so it "
                + "logs nothing, emits nothing and calls no delegate, and from outside the app it is "
                + "indistinguishable from a store that refused. Frames are in the log above.",
        )

        /*
         And hittable is not the same as working — a tap on a view that LOOKS like the CTA can land on
         an overlay above it and XCUITest reports no error (the disabled-button lesson). So the tap is
         actually sent and STOREKIT'S OWN LEDGER is checked for a second attempt.

         🔴 The ledger, not `host.lastEvents`. This step used to wait for "purchase" in the host's
         event mirror — which is drawn in the host's view, UNDERNEATH the presented paywall, so it is
         not in the accessibility tree while the paywall is up. The step failed on every run (7 of 7
         on 2026-10-24, whatever the SDK did), which made this test unable to tell #1072 from a
         working CTA. A refused attempt is recorded too, so ANY new transaction is the attempt.
        */
        sleep(2) // measured (#1107): a purchase sent straight after re-enabling can still come back failed
        let attemptsBefore = session.allTransactions().count
        after.tap()
        let sawRetry = waitUntil(timeout: 20) { session.allTransactions().count > attemptsBefore }
        NSLog("[#1072] after the retry tap, the ledger: \(session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" })")
        XCTAssertTrue(
            sawRetry,
            "tapping the CTA after a failed purchase put no new transaction in the ledger — the tap "
                + "reached no action. That is #1072: no transaction, and no sign of why.",
        )
    }

    /*
     #1105 — THE FAILURE BANNER, OPERATED. iOS's banner is the presentation both platforms now draw,
     so this walks the paywall the way a user whose card is declined would, against a paywall that
     authors `on_failure: retry` with text no default could produce
     (`scripts/spec502/probe-1105-failure-banner-walk.ts`):

       refused purchase → the authored banner, ABOVE the CTA, which stays usable
       → tap the banner → it is gone, and stays gone
       → refused AGAIN (the same failure twice — what resurrected Android's banner) → banner
       → tap the banner once → gone and stays gone.

     Every step saves a frame to the Mac's /tmp (and attaches it), because "rendered correctly" is
     half a result: the frames are what the closing evidence shows.
    */
    @available(iOS 17.0, *)
    func testTheFailureBannerIsAboveTheCtaAndTapsAway() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions(); session.failTransactionsEnabled = false }

        let app = XCUIApplication()
        app.launchArguments = ["-appdnaApiKey", apiKey, "-appdnaPaywall", paywallId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        // Open the paywall only once the WHOLE remote config has landed, so the walk measures the
        // published document rather than whatever was in memory before the fetch completed.
        let events = app.staticTexts["host.lastEvents"]
        let fetched = waitUntil(timeout: 45) { events.exists && events.label.contains("config_fetched") }
        NSLog("[#1105] config_fetched before opening the paywall: \(fetched) — events: \(events.exists ? events.label : "(absent)")")
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        var cta: XCUIElement?
        for _ in 0..<12 where cta == nil {
            if open.isHittable { open.tap() }
            _ = app.buttons.firstMatch.waitForExistence(timeout: 5)
            cta = ctaButton(app)
        }
        let button = try XCTUnwrap(cta, "no CTA button was found on the paywall")
        shot(app, "01-paywall")

        // 1 — a refused purchase draws the AUTHORED banner, above the CTA.
        session.failTransactionsEnabled = true
        button.tap()
        let start = Date()
        let up = waitUntil(timeout: 60) { self.authoredBanner(app).exists }
        NSLog("[#1105] banner up=\(up) after \(String(format: "%.1f", Date().timeIntervalSince(start)))s; cta enabled=\(ctaButton(app)?.isEnabled ?? false)")
        shot(app, "02-banner")
        if !up {
            // Say WHY before failing: close the paywall and read what the host app recorded.
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "close")).firstMatch.tap()
            let events = app.staticTexts["host.lastEvents"]
            _ = events.waitForExistence(timeout: 5)
            NSLog("[#1105] host events after the refusal: \(events.exists ? events.label : "(absent)")")
        }
        XCTAssertTrue(up, "no banner within 60s of a refused purchase")
        guard up else { return }
        let banner = authoredBanner(app)
        let after = try XCTUnwrap(ctaButton(app))
        NSLog("[#1105] banner text frame=\(banner.frame) cta frame=\(after.frame)")
        XCTAssertLessThanOrEqual(banner.frame.maxY, after.frame.minY, "the banner's text overlaps the CTA")
        XCTAssertTrue(after.isEnabled && after.isHittable, "the CTA is not usable with the banner up")
        // The retry control is a Button, so it is matched among buttons, by its authored label.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Try again now")).firstMatch.exists,
                      "the authored retry text is not on the banner")

        // 2 — one tap on the banner hides it, and it stays hidden.
        tapWhenSettled(banner)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.authoredBanner(app).exists }, "the banner did not go on tap")
        sleep(3)
        XCTAssertFalse(authoredBanner(app).exists, "the banner came back after it was tapped away")
        shot(app, "03-tapped-away")

        // 3 — the SAME failure twice, then one tap: still gone.
        after.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.authoredBanner(app).exists }, "no banner after the second refusal")
        shot(app, "04-second-refusal")
        tapWhenSettled(authoredBanner(app))
        sleep(3)
        XCTAssertFalse(authoredBanner(app).exists, "after a second identical failure, one tap did not keep the banner away")
        shot(app, "05-tapped-away-again")
    }

    /*
     #1107 — THE RETRY BUYS. A refused purchase, then the store is allowed to accept, then the
     banner's retry pill is tapped: a StoreKit transaction must follow. The old pill only hid the
     banner, so nothing was bought until the user found the purchase button themselves.
    */
    @available(iOS 17.0, *)
    func testTheRetryButtonBuysAgain() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions(); session.failTransactionsEnabled = false }

        let app = XCUIApplication()
        app.launchArguments = ["-appdnaApiKey", apiKey, "-appdnaPaywall", paywallId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        let events = app.staticTexts["host.lastEvents"]
        _ = waitUntil(timeout: 45) { events.exists && events.label.contains("config_fetched") }
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        var cta: XCUIElement?
        for _ in 0..<12 where cta == nil {
            if open.isHittable { open.tap() }
            _ = app.buttons.firstMatch.waitForExistence(timeout: 5)
            cta = ctaButton(app)
        }
        let button = try XCTUnwrap(cta, "no CTA button was found on the paywall")

        session.failTransactionsEnabled = true
        button.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { self.authoredBanner(app).exists }, "no banner after the refusal")
        // The session records the refused attempt too (as a failed transaction), so count PURCHASES.
        let purchased = { session.allTransactions().filter { $0.state == .purchased } }
        XCTAssertTrue(purchased().isEmpty, "a purchase was recorded for the REFUSED attempt")
        shot(app, "r1-banner")

        session.failTransactionsEnabled = false
        // Measured: a purchase sent straight after re-enabling still came back failed, so give the
        // session a moment. Whatever the outcome, an ATTEMPT is what the old pill never made.
        sleep(2)
        let attemptsBefore = session.allTransactions().count
        let retry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Try again now")).firstMatch
        XCTAssertTrue(retry.exists, "no retry button on the banner")
        retry.tap()
        let attempted = waitUntil(timeout: 20) { session.allTransactions().count > attemptsBefore }
        _ = waitUntil(timeout: 10) { !purchased().isEmpty }
        shot(app, "r2-after-retry")
        NSLog("[#1107] after the retry tap: all=\(session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" }) purchased=\(purchased().map { $0.productIdentifier })")
        XCTAssertTrue(attempted, "tapping the retry button started no purchase — it only hid the banner (#1107)")
    }

    /*
     #1109 — A PAYWALL'S PURCHASE CELEBRATION REACHES THE DEVICE. The effect could not be stored
     before, so no published paywall carried one. The walk paywall is given confetti in `#34C759` (a
     green it has nowhere else) by `scripts/spec502/probe-1109-paywall-effect-persists.ts --keep`; a
     purchase that succeeds must then put that green on screen. The confetti is not in the
     accessibility tree, so the PIXELS are read; run against the paywall with the effect cleared, the
     same test must fail — that is its control.
    */
    @available(iOS 17.0, *)
    func testThePurchaseCelebrationDraws() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let app = XCUIApplication()
        app.launchArguments = ["-appdnaApiKey", apiKey, "-appdnaPaywall", paywallId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        let events = app.staticTexts["host.lastEvents"]
        _ = waitUntil(timeout: 45) { events.exists && events.label.contains("config_fetched") }
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        var cta: XCUIElement?
        for _ in 0..<12 where cta == nil {
            if open.isHittable { open.tap() }
            _ = app.buttons.firstMatch.waitForExistence(timeout: 5)
            cta = ctaButton(app)
        }
        let button = try XCTUnwrap(cta, "no CTA button was found on the paywall")
        sleep(1)
        let before = greenPixels(app.screenshot().image)
        shot(app, "c1-before-purchase")

        button.tap()
        var peak = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 8 {
            let frame = app.screenshot()
            let n = greenPixels(frame.image)
            if n > peak {
                peak = n
                let a = XCTAttachment(data: frame.pngRepresentation, uniformTypeIdentifier: "public.png")
                a.name = "c2-celebration-peak"; a.lifetime = .keepAlways; add(a)
                try? frame.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/ios-walk-1109-c2-celebration-peak.png"))
            }
            usleep(150_000)
        }
        let purchased = session.allTransactions().filter { $0.state == .purchased }.map(\.productIdentifier)
        NSLog("[#1109] green pixels before=\(before) peak after purchase=\(peak) purchased=\(purchased)")
        XCTAssertFalse(purchased.isEmpty, "the purchase did not complete, so there was nothing to celebrate")
        XCTAssertGreaterThan(peak, before + 300, "no confetti in the authored green after a successful purchase (#1109)")
    }

    /*
     #1104 — WHAT THE CTA SAYS, READ OFF THE DEVICE. The walk paywall is published by
     `scripts/spec502/probe-1104-cta-plan-name-walk.ts` with a format, naming switched off, and/or a
     sticky footer; this logs every CTA label (the pinned CTA and the sticky footer's) with the default
     plan and then with Monthly selected. The invariant asserted here holds for every configuration:
     a label that named the default plan names Monthly once Monthly is selected. The exact strings are
     compared against the published configuration in the closing evidence.
    */
    @available(iOS 17.0, *)
    func testTheCtaLabelsAsAuthored() throws {
        guard let apiKey, let paywallId else {
            throw XCTSkip("TestCredentials is empty — run via scripts/sdk-host-ios.ts --uitest")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-appdnaApiKey", apiKey, "-appdnaPaywall", paywallId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        let events = app.staticTexts["host.lastEvents"]
        _ = waitUntil(timeout: 45) { events.exists && events.label.contains("config_fetched") }
        let open = app.buttons["host.paywall"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let ctaLabels: () -> [String] = {
            app.buttons.allElementsBoundByIndex.map(\.label)
                .filter { $0.contains("Continue") || $0.contains("Get it") }
        }
        for _ in 0..<12 where ctaLabels().isEmpty {
            if open.isHittable { open.tap() }
            _ = app.buttons.firstMatch.waitForExistence(timeout: 5)
        }
        sleep(1)
        let before = ctaLabels()
        shot(app, "l1-default-plan")
        let monthly = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Monthly")).firstMatch
        XCTAssertTrue(monthly.waitForExistence(timeout: 5), "no Monthly plan row")
        monthly.tap()
        sleep(1)
        let after = ctaLabels()
        shot(app, "l2-monthly-selected")
        NSLog("[#1104] CTA labels, default plan: \(before)")
        NSLog("[#1104] CTA labels, Monthly selected: \(after)")
        XCTAssertFalse(before.isEmpty, "no CTA was found")
        for label in before where label.contains("Annual") {
            XCTAssertTrue(after.contains(label.replacingOccurrences(of: "Annual", with: "Monthly")),
                          "'\(label)' did not follow the selection to Monthly: \(after)")
        }
    }

    /// Pixels close to `#34C759` (52, 199, 89) — the walk effect's own colour.
    private func greenPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var n = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[i]) - 52) < 30 && abs(Int(bytes[i + 1]) - 199) < 30 && abs(Int(bytes[i + 2]) - 89) < 30 { n += 1 }
        }
        return n
    }

    // MARK: - helpers

    /// The banner's authored message on the #1105 walk paywall.
    private func authoredBanner(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Walk 1105")).firstMatch
    }

    /// A frame on the Mac's /tmp for the closing evidence, and attached to the result bundle.
    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? png.write(to: URL(fileURLWithPath: "/tmp/ios-walk-1105-\(name).png"))
    }

    /// The pinned CTA. Matched by its accessibility identifier where the renderer sets one, else by
    /// being the paywall's purchase button — never by position, which is what this test measures.
    /// #1100 appends the selected plan's name ("Continue — Annual"), so a label PREFIX is accepted.
    private func ctaButton(_ app: XCUIApplication) -> XCUIElement? {
        let byId = app.buttons["paywall.cta"]
        if byId.exists { return byId }
        for label in ["Start Free Trial", "Continue", "Subscribe", "Start My Plan"] {
            let b = app.buttons[label]
            if b.exists { return b }
            let prefixed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label + " — ")).firstMatch
            if prefixed.exists { return prefixed }
        }
        return nil
    }

    private func bannerElement(_ app: XCUIApplication) -> XCUIElement? {
        // The banner draws `errorMessage` as a static text over the bottom of the screen.
        for fragment in ["Payment failed", "failed", "declined", "error", "Try Again"] {
            let t = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
            if t.exists { return t }
        }
        return nil
    }

    private func bannerIsUp(_ app: XCUIApplication) -> Bool { bannerElement(app) != nil }

    /*
     #1111 — TAP THE BANNER WHERE IT IS DRAWN, NOT WHERE IT IS ARRIVING FROM. The banner slides in
     from the bottom edge, and it is in the accessibility tree from the first frame of that
     transition — screenshot `04-second-refusal` shows it "existing" with nothing yet on screen. A tap
     sent then lands on the empty space it is moving through. That used to dismiss it anyway, because
     the dismiss gesture covered the whole SCREEN — which is the #1111 defect: the same catcher ate
     every tap on the CTA. With the gesture scoped to the card, the tap has to hit the card, so the
     frame is polled until it stops moving.
    */
    private func tapWhenSettled(_ element: XCUIElement) {
        var last = element.frame
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let now = element.frame
            if now == last && element.isHittable { break }
            last = now
        }
        element.tap()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }
}

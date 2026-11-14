// PaywallAccentSelectionWalkUITests.swift
//
// FOUR PAYWALL BEHAVIOURS, OPERATED ON THE SIMULATOR.
//
//   1. A purchase that fails on a paywall with NO `post_purchase.on_failure` shows the error banner,
//      both for a product the store does not have and for a purchase the store refuses.
//   2. A plan badge carrying `{{savings_percent}}` states the saving at the prices the paywall DRAWS,
//      which are the store's here (`Products.storekit`: $4.49 / month, $34.99 / year → 35%).
//   3. The trial badge, a plan's trial line and its feature checks take the paywall's accent (the
//      CTA's authored colour), and an authored `badge_color` wins over it.
//   4. Every card plan layout draws a selection circle at the card's top trailing corner, and it follows
//      the selection when a plan is tapped.
//
// `TestCredentials.paywallId` carries `key=id` pairs separated by commas, one paywall per walk:
//   fail, savings, accent, grid, horizontal_scroll, carousel_cards, mini_cards, single_hero.
// A walk whose key is absent SKIPS. The paywalls are published by a seeding script in the AppDNA
// repository; their colours are chosen to appear nowhere else on screen, so pixels can be counted.
//
// Every step saves a frame to the Mac's /tmp/ios-walk-j4-<name>.png and attaches it.
import XCTest
import StoreKitTest

final class PaywallAccentSelectionWalkUITests: XCTestCase {

    private var apiKey: String? { TestCredentials.apiKey.isEmpty ? nil : TestCredentials.apiKey }

    private func paywall(_ key: String) -> String? {
        for pair in TestCredentials.paywallId.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == key, !kv[1].isEmpty { return kv[1] }
        }
        return nil
    }

    // MARK: - 1. A failed purchase is never silent

    @available(iOS 17.0, *)
    func testAFailedPurchaseWithNoFailureConfigShowsTheBanner() throws {
        guard let apiKey, let id = paywall("fail") else { throw XCTSkip("no `fail` paywall in TestCredentials") }
        let session = try storeSession()
        defer { session.clearTransactions(); session.failTransactionsEnabled = false }
        let app = try open(id, apiKey: apiKey, name: "fail")

        // The plans are operated first: each row is tapped and reports itself selected.
        let monthly = try planRow(app, "Monthly")
        let missing = try planRow(app, "Lifetime")
        monthly.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { monthly.isSelected }, "the Monthly row did not take the selection")
        missing.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { missing.isSelected }, "the Lifetime row did not take the selection")
        shot(app, "fail-01-lifetime-selected")

        // (a) A product the store does not have: the purchase fails at once ("Product not found").
        let cta = try XCTUnwrap(ctaButton(app), "no CTA")
        cta.tap()
        let upA = waitUntil(timeout: 30) { self.defaultBanner(app).exists }
        shot(app, "fail-02-product-not-found-banner")
        XCTAssertTrue(upA, "no banner after a purchase of a product the store does not have")
        XCTAssertTrue(waitUntil(timeout: 5) { self.ctaButton(app)?.isEnabled == true }, "the CTA was not re-enabled")
        tapWhenSettled(defaultBanner(app))
        XCTAssertTrue(waitUntil(timeout: 5) { !self.defaultBanner(app).exists }, "the banner did not go on tap")
        shot(app, "fail-03-banner-tapped-away")

        // (b) A product the store has, and the store refuses the purchase.
        monthly.tap()
        session.failTransactionsEnabled = true
        try XCTUnwrap(ctaButton(app)).tap()
        let upB = waitUntil(timeout: 30) { self.defaultBanner(app).exists }
        shot(app, "fail-04-store-refused-banner")
        XCTAssertTrue(upB, "no banner after the store refused the purchase")
        let purchased = session.allTransactions().filter { $0.state == .purchased }
        XCTAssertTrue(purchased.isEmpty, "a refused purchase was recorded as bought")
        NSLog("[j4-fail] banner after not-found=\(upA) after refusal=\(upB) ledger=\(session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" })")
    }

    // MARK: - 2. The savings figure follows the prices drawn

    @available(iOS 17.0, *)
    func testTheSavingsBadgeStatesTheSavingAtTheStorePrices() throws {
        guard let apiKey, let id = paywall("savings") else { throw XCTSkip("no `savings` paywall in TestCredentials") }
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = try open(id, apiKey: apiKey, name: "savings")

        // The store's prices are drawn, not the authored $39.99 / $6.99.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "34.99")).firstMatch.waitForExistence(timeout: 10),
                      "the store's annual price is not drawn")
        // 1 − 34.99 / (4.49 × 12) = 35.06% → floored to 35.
        let badge = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "save 35%")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the badge does not state 35%: \(allTexts(app))")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "52%")).firstMatch.exists,
                       "the authored-price saving (52%) is drawn")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "{{")).firstMatch.exists,
                       "an unfilled token is drawn")
        shot(app, "savings-01-store-prices")
        NSLog("[j4-savings] texts: \(allTexts(app))")

        // Operate it: select monthly, then annual, and buy annual.
        let monthly = try planRow(app, "Monthly")
        monthly.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { monthly.isSelected })
        shot(app, "savings-02-monthly-selected")
        let annual = try planRow(app, "Annual")
        annual.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { annual.isSelected })
        try XCTUnwrap(ctaButton(app)).tap()
        let bought = waitUntil(timeout: 30) { session.allTransactions().contains { $0.state == .purchased } }
        shot(app, "savings-03-after-purchase")
        let ledger = session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" }
        NSLog("[j4-savings] ledger after the CTA: \(ledger)")
        XCTAssertTrue(bought, "the CTA bought nothing")
        XCTAssertTrue(session.allTransactions().contains { $0.state == .purchased && $0.productIdentifier == "premium_annual" },
                      "the CTA did not buy the selected annual plan: \(ledger)")
    }

    // MARK: - 3. The paywall's accent

    /// The accent paywall's CTA is #D1149E; its first trial badge has no colour, its second is authored #0FA36B.
    @available(iOS 17.0, *)
    func testTheTrialBadgeAndPlanAccentsTakeThePaywallsAccent() throws {
        guard let apiKey, let id = paywall("accent") else { throw XCTSkip("no `accent` paywall in TestCredentials") }
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = try open(id, apiKey: apiKey, name: "accent")
        sleep(1)
        let cta = try XCTUnwrap(ctaButton(app))
        let frame = app.screenshot()
        shot(app, "accent-01-paywall")
        // Count above the CTA, so the CTA's own fill is not what is measured.
        let scale = frame.image.scale
        let ceiling = Int(cta.frame.minY * scale) - 4
        let magenta = pixels(frame.image, maxY: ceiling) { r, g, b in abs(r - 209) < 30 && abs(g - 20) < 30 && abs(b - 158) < 30 }
        let green = pixels(frame.image, maxY: ceiling) { r, g, b in abs(r - 15) < 30 && abs(g - 163) < 30 && abs(b - 107) < 30 }
        let indigo = pixels(frame.image, maxY: ceiling) { r, g, b in abs(r - 99) < 20 && abs(g - 102) < 20 && abs(b - 241) < 20 }
        NSLog("[j4-accent] above the CTA: magenta=\(magenta) green=\(green) indigo=\(indigo) (ceiling \(ceiling)px)")
        XCTAssertGreaterThan(magenta, 150, "the trial badge / trial line / feature checks are not in the CTA's colour")
        XCTAssertGreaterThan(green, 150, "the badge with an authored colour is not drawn in it")
        // Indigo is still expected above the CTA: the selected plan's border and circle take `selected_border_color`,
        // which this paywall leaves unset (brand accent). Logged, not asserted — those have their own colour field.

        // Operate: tap each plan, then buy.
        let monthly = try planRow(app, "Monthly")
        monthly.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { monthly.isSelected })
        shot(app, "accent-02-monthly-selected")
        let annual = try planRow(app, "Annual")
        annual.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { annual.isSelected })
        shot(app, "accent-03-annual-selected")
        try XCTUnwrap(ctaButton(app)).tap()
        let bought = waitUntil(timeout: 30) { session.allTransactions().contains { $0.state == .purchased } }
        NSLog("[j4-accent] ledger: \(session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" })")
        XCTAssertTrue(bought, "the CTA bought nothing")
    }

    // MARK: - 4. The selection circle on every card layout

    /// Each layout paywall authors `selected_border_color` #FF6A00 and `unselected_border_color` #1E90FF, so the
    /// filled circle on the selected card and the ring on the others can be found by colour in each card's top
    /// trailing corner.
    @available(iOS 17.0, *)
    func testEveryCardLayoutDrawsTheSelectionCircle() throws {
        guard let apiKey else { throw XCTSkip("no api key") }
        let layouts = ["grid", "horizontal_scroll", "carousel_cards", "mini_cards", "single_hero"].filter { paywall($0) != nil }
        guard !layouts.isEmpty else { throw XCTSkip("no layout paywalls in TestCredentials") }
        let session = try storeSession()
        defer { session.clearTransactions() }
        var report: [String] = []
        for layout in layouts {
            let app = try open(paywall(layout)!, apiKey: apiKey, name: layout)
            sleep(1)
            var rows: [(String, XCUIElement)] = []
            for name in ["Annual", "Monthly"] {
                // The plan card, never the CTA ("Continue — Annual" also names the plan).
                let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ AND NOT (label CONTAINS[c] %@)", name, "Continue")).firstMatch
                if row.exists && row.isHittable { rows.append((name, row)) }
            }
            XCTAssertFalse(rows.isEmpty, "[\(layout)] no plan card is on screen")
            for (name, row) in rows {
                row.tap()
                XCTAssertTrue(waitUntil(timeout: 3) { row.isSelected }, "[\(layout)] tapping \(name) did not select it")
                sleep(1)
                let frame = app.screenshot()
                shot(app, "\(layout)-\(name.lowercased())-selected")
                // The card's trailing 44pt column holds the circle (top trailing on the custom cards, the row end on PlanCard).
                let s = frame.image.scale
                let box = CGRect(x: (row.frame.maxX - 44) * s, y: row.frame.minY * s, width: 44 * s, height: row.frame.height * s)
                let orange = pixels(frame.image, in: box) { r, g, b in abs(r - 255) < 30 && abs(g - 106) < 35 && b < 60 }
                NSLog("[j4-circle] \(layout) \(name) selected: frame=\(row.frame) orange in the top trailing corner=\(orange)")
                report.append("\(layout)/\(name)=\(orange)")
                XCTAssertGreaterThan(orange, 40, "[\(layout)] no filled selection circle in \(name)'s top trailing corner")
                for (other, otherRow) in rows where other != name {
                    let ob = CGRect(x: (otherRow.frame.maxX - 44) * s, y: otherRow.frame.minY * s, width: 44 * s, height: otherRow.frame.height * s)
                    let blue = pixels(frame.image, in: ob) { r, g, b in abs(r - 30) < 35 && abs(g - 144) < 35 && abs(b - 255) < 35 }
                    NSLog("[j4-circle] \(layout) \(other) unselected: ring pixels=\(blue)")
                    XCTAssertGreaterThan(blue, 20, "[\(layout)] no ring on the unselected \(other) card")
                }
            }
            let layoutCta = try XCTUnwrap(ctaButton(app), "[\(layout)] no CTA")
            NSLog("[j4-circle] \(layout) CTA '\(layoutCta.label)' frame=\(layoutCta.frame) enabled=\(layoutCta.isEnabled) hittable=\(layoutCta.isHittable)")
            layoutCta.tap()
            sleep(2)
            shot(app, "\(layout)-after-cta")
            let bought = waitUntil(timeout: 30) { session.allTransactions().contains { $0.state == .purchased } }
            if !bought { shot(app, "\(layout)-cta-30s"); NSLog("[j4-circle] \(layout) texts after CTA: \(allTexts(app))") }
            NSLog("[j4-circle] \(layout) CTA ledger: \(session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" })")
            XCTAssertTrue(bought, "[\(layout)] the CTA bought nothing")
            session.clearTransactions()
            app.terminate()
        }
        NSLog("[j4-circle] report: \(report)")
    }

    // MARK: - 5. The horizontal_scroll CTA buys, every time

    /*
     Two of three full-class runs saw the horizontal_scroll CTA put NO transaction in the ledger, while every other
     layout bought; a run of grid + horizontal_scroll alone bought. The full class differs in one thing: the failure
     walk runs first and leaves REFUSED transactions of `premium_monthly`, then grid buys `premium_monthly`, then
     horizontal_scroll buys `premium_monthly` again. So the hypotheses are separated by the order of purchases, not by
     the layout:
       H1 (store state)  the second purchase of a product after refused / cleared ones yields no new transaction;
                         the SDK still reports purchase_started (and then completed or failed).
       H2 (the layout)   the CTA tap on horizontal_scroll is dropped or buys nothing whatever came before:
                         no purchase_started at all.
       H1' (already owned) `clearTransactions()` had not yet removed the entitlement grid just bought, so the
                         re-buy returned the EXISTING transaction: StoreKit adds nothing to the ledger, and the SDK
                         reports `purchase_restored` (item_already_owned), which is what the real App Store does for a
                         user who already owns the subscription. `restored=true` with no new ledger entry names it.
     A refused purchase followed by a retry of the same product bought on grid in both failing runs (grid came
     after the failure walk's refusals), so the decline-then-retry path itself was exercised and worked.
     Each leg launches fresh, selects Monthly (the product the failing runs bought), taps the CTA, and records
     whether the tap reached the SDK (the host's event log, read after the paywall is closed), what StoreKit
     recorded, and a frame 2 s and 30 s after the tap.
    */
    @available(iOS 17.0, *)
    func testTheHorizontalScrollCtaBuysEveryTime() throws {
        guard let apiKey, let hs = paywall("horizontal_scroll"), let grid = paywall("grid") else {
            throw XCTSkip("needs horizontal_scroll= and grid= in TestCredentials")
        }
        let session = try storeSession()
        defer { session.clearTransactions(); session.failTransactionsEnabled = false }
        // Legs: horizontal_scroll alone ×3; after a refused purchase of the same product; after grid bought it.
        let legs: [(String, String, String?)] = [
            ("hs-alone-1", hs, nil), ("hs-alone-2", hs, nil), ("hs-alone-3", hs, nil),
            ("hs-after-refusal", hs, "refuse"), ("hs-after-grid", hs, "grid"),
            ("grid-after-grid", grid, "grid"),
        ]
        var results: [String] = []
        for (name, id, before) in legs {
            session.clearTransactions()
            if before == "refuse" {
                session.failTransactionsEnabled = true
                let pre = try open(id, apiKey: apiKey, name: name + "-pre")
                try planRow(pre, "Monthly").tap(); sleep(1)
                try XCTUnwrap(ctaButton(pre)).tap()
                _ = waitUntil(timeout: 30) { self.defaultBanner(pre).exists }
                pre.terminate()
                session.failTransactionsEnabled = false
            } else if before == "grid" {
                let pre = try open(grid, apiKey: apiKey, name: name + "-pre")
                try planRow(pre, "Monthly").tap(); sleep(1)
                try XCTUnwrap(ctaButton(pre)).tap()
                _ = waitUntil(timeout: 30) { session.allTransactions().contains { $0.state == .purchased } }
                pre.terminate()
                session.clearTransactions()
            }
            let app = try open(id, apiKey: apiKey, name: name)
            let monthly = try planRow(app, "Monthly")
            monthly.tap()
            XCTAssertTrue(waitUntil(timeout: 3) { monthly.isSelected }, "[\(name)] Monthly did not take the selection")
            let cta = try XCTUnwrap(ctaButton(app))
            let ctaLabel = cta.label
            let countBefore = session.allTransactions().count
            cta.tap()
            sleep(2); shot(app, "hs-\(name)-2s")
            let bought = waitUntil(timeout: 30) { session.allTransactions().count > countBefore }
            shot(app, "hs-\(name)-30s")
            // Close the paywall if it is still up, then read what the SDK reported to the host.
            let close = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "close")).firstMatch
            if close.exists { close.tap(); sleep(1) }
            let events = app.staticTexts["host.lastEvents"]
            _ = events.waitForExistence(timeout: 5)
            let log = events.exists ? events.label : "(absent)"
            let ledger = session.allTransactions().map { "\($0.productIdentifier):\($0.state.rawValue)" }
            let line = "\(name): cta='\(ctaLabel)' bought=\(bought) ledger=\(ledger) started=\(log.contains("purchase_started")) completed=\(log.contains("purchase_completed")) failed=\(log.contains("purchase_failed")) restored=\(log.contains("purchase_restored"))"
            NSLog("[j4-hs] \(line) events=\(log.prefix(400))")
            results.append(line)
            app.terminate()
        }
        NSLog("[j4-hs] summary:\n\(results.joined(separator: "\n"))")
        for r in results { XCTAssertTrue(r.contains("bought=true"), "the CTA bought nothing: \(r)") }
    }

    // MARK: - helpers

    @available(iOS 17.0, *)
    private func storeSession() throws -> SKTestSession {
        guard let url = Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit") else {
            throw XCTSkip("Products.storekit is not in the UI-test bundle")
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    /// Launches the host on one paywall, waits for the remote config, and presents it.
    private func open(_ paywallId: String, apiKey: String, name: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appdnaApiKey", apiKey, "-appdnaPaywall", paywallId]
        app.launch()
        XCTAssertTrue(app.staticTexts["host.title"].waitForExistence(timeout: 20))
        let events = app.staticTexts["host.lastEvents"]
        _ = waitUntil(timeout: 45) { events.exists && events.label.contains("config_fetched") }
        let openButton = app.buttons["host.paywall"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))
        var cta: XCUIElement?
        for _ in 0..<12 where cta == nil {
            if openButton.isHittable { openButton.tap() }
            _ = app.buttons.firstMatch.waitForExistence(timeout: 5)
            cta = ctaButton(app)
        }
        _ = try XCTUnwrap(cta, "[\(name)] the paywall did not present")
        return app
    }

    private func planRow(_ app: XCUIApplication, _ name: String) throws -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ AND NOT (label CONTAINS[c] %@)", name, "Continue")).firstMatch
        let found = row.waitForExistence(timeout: 5) ? row
            : app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label CONTAINS[c] %@)", name, "Continue")).firstMatch
        return try XCTUnwrap(found.exists ? found : nil, "no \(name) plan row")
    }

    private func defaultBanner(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Payment failed. Please try again.")).firstMatch
    }

    private func ctaButton(_ app: XCUIApplication) -> XCUIElement? {
        let byId = app.buttons["paywall.cta"]
        if byId.exists { return byId }
        for label in ["Start Free Trial", "Continue", "Subscribe"] {
            let b = app.buttons[label]
            if b.exists { return b }
            let prefixed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label + " — ")).firstMatch
            if prefixed.exists { return prefixed }
        }
        return nil
    }

    private func allTexts(_ app: XCUIApplication) -> [String] {
        app.staticTexts.allElementsBoundByIndex.prefix(60).map(\.label)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? png.write(to: URL(fileURLWithPath: "/tmp/ios-walk-j4-\(name).png"))
    }

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

    /// Pixels matching `match` (r, g, b) in `rect` (image pixels), or above `maxY` when no rect is given.
    private func pixels(_ image: UIImage, in rect: CGRect? = nil, maxY: Int? = nil, _ match: (Int, Int, Int) -> Bool) -> Int {
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
        let r = (rect ?? CGRect(x: 0, y: 0, width: w, height: min(h, maxY ?? h))).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !r.isNull else { return 0 }
        var n = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let i = (y * w + x) * 4
                if match(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])) { n += 1 }
            }
        }
        return n
    }
}

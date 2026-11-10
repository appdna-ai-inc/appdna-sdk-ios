import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// The themed date wheel in a real key window: its selection band takes `highlight_color`, and it is operated the way
/// VoiceOver operates it. THE CONTROL: a calendar the themed wheel does not number keeps UIKit's wheel, whose band ignores
/// the colour, so the count is zero there. That is the old band, and it is what these assertions go red on.
final class ThemedDateWheelRenderTests: XCTestCase {
    private var windows: [UIWindow] = []
    override func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
        super.tearDown()
    }

    private func block(_ highlight: String, mode: String = "date", date: String = "2000-06-15") throws -> ContentBlock {
        let json: [String: Any] = ["id": "w", "type": "date_wheel_picker", "field_id": "born", "picker_mode": mode, "highlight_color": highlight,
                                   "default_date_value": date, "wheel_height": 200, "field_config": ["picker_variant": "wheel"]]
        return try JSONDecoder().decode(ContentBlock.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private final class Store { var inputs: [String: Any] = [:] }

    private func show(_ block: ContentBlock, calendar: Calendar, store: Store = Store()) -> (UIHostingController<AnyView>, UIWindow) {
        let binding = Binding<[String: Any]>(get: { store.inputs }, set: { store.inputs = $0 })
        let root = AnyView(DateWheelPickerBlockView(block: block, inputValues: binding)
            .environment(\.calendar, calendar)
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: 360, height: 260)
            .background(Color.white)
            .colorScheme(.light))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 260))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        windows.append(window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (host, window)
    }

    /// Pixels in the band's row that lean to the given channel.
    private func tinted(_ view: UIView, red: Bool) -> Int {
        let renderer = UIGraphicsImageRenderer(size: view.bounds.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { ctx in view.layer.render(in: ctx.cgContext) }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: cg.height, by: 2) {
            for x in stride(from: 0, to: 14, by: 1) {
                let o = y * cg.bytesPerRow + x * 4
                let (b, g, r) = (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
                if red ? (r > g + 8 && r > b + 8) : (b > g + 8 && b > r + 8) { count += 1 }
            }
        }
        return count
    }

    private func wheels(in view: UIView) -> [WheelScrollView] {
        var out: [WheelScrollView] = []
        func walk(_ v: UIView) { if let w = v as? WheelScrollView { out.append(w) }; v.subviews.forEach(walk) }
        walk(view)
        return out
    }

    func testTheBandTakesTheHighlightColour() throws {
        let (host, _) = show(try block("#FF0000"), calendar: Calendar(identifier: .gregorian))
        XCTAssertGreaterThan(tinted(host.view, red: true), 20, "the band is drawn in the flow's colour")
        XCTAssertEqual(tinted(host.view, red: false), 0)
    }

    func testAnotherHighlightMovesTheBand() throws {
        let (host, _) = show(try block("#0000FF"), calendar: Calendar(identifier: .gregorian))
        XCTAssertGreaterThan(tinted(host.view, red: false), 20)
        XCTAssertEqual(tinted(host.view, red: true), 0)
    }

    func testTheControlTheNativeWheelBandIgnoresTheColour() throws {
        let (host, _) = show(try block("#FF0000"), calendar: Calendar(identifier: .japanese))
        XCTAssertEqual(wheels(in: host.view).count, 0, "this calendar keeps UIKit's wheel")
        XCTAssertEqual(tinted(host.view, red: true), 0, "UIKit's band is not the flow's colour")
    }

    func testColumnsFollowTheModeAndAreAdjustable() throws {
        let (date, _) = show(try block("#FF0000"), calendar: Calendar(identifier: .gregorian))
        let columns = wheels(in: date.view)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns.map { $0.accessibilityLabel ?? "" }, ["Month", "Day", "Year"], "en_US order")
        XCTAssertTrue(columns[0].accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(columns[0].accessibilityValue, "Jun")
        XCTAssertEqual(columns[1].accessibilityValue, "15")

        let (year, _) = show(try block("#FF0000", mode: "year"), calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(wheels(in: year.view).map { $0.accessibilityLabel ?? "" }, ["Year"])
    }

    func testAVoiceOverStepStoresTheAnswerAndClampsTheMonth() throws {
        let store = Store()
        let (host, _) = show(try block("#FF0000", date: "2023-01-31"), calendar: Calendar(identifier: .gregorian), store: store)
        let month = try XCTUnwrap(wheels(in: host.view).first { $0.accessibilityLabel == "Month" })
        month.accessibilityIncrement()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let day = try XCTUnwrap(wheels(in: host.view).first { $0.accessibilityLabel == "Day" })
        XCTAssertEqual(month.accessibilityValue, "Feb")
        XCTAssertEqual(day.accessibilityValue, "28", "January 31 moved to February comes down to the last real day")
        XCTAssertNotNil(store.inputs["born"])
    }

    func testYearModeStoresFourDigits() throws {
        let store = Store()
        let (host, _) = show(try block("#FF0000", mode: "year", date: "2000-06-15"), calendar: Calendar(identifier: .gregorian), store: store)
        try XCTUnwrap(wheels(in: host.view).first).accessibilityIncrement()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(store.inputs["born"] as? String, "2001")
    }
}

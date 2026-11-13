import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// The compact date field's sheet draws its wheel in the same scheme as the sheet behind it, in either phone appearance.
/// It used to force the wheel light while the sheet followed the phone, so a phone in Dark drew black rows on a dark
/// sheet. THE CONTROL: with the phone in Light the sheet is light and its rows dark, so a pass is not a sheet that is
/// always drawn dark.
final class CompactDateSheetRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    // MARK: - What the sheet draws

    private struct Ink { let fill: CGFloat; let brightest: CGFloat; let darkest: CGFloat }

    /// The sheet's fill (a corner) and the extremes of what is drawn in the wheel's selected row.
    private func ink(scheme: ColorScheme, phone: ColorScheme) -> Ink {
        var date = Date(timeIntervalSince1970: 961_027_200) // 2000-06-15
        let binding = Binding<Date>(get: { date }, set: { date = $0 })
        let sheet = CompactDateSheet(selection: binding, components: .date, accent: Color(hex: "#6366F1"),
                                     locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!,
                                     scheme: scheme, onDone: {})
        let view = host.show(sheet, background: "#FF00FF", scheme: phone).view!
        XCTAssertEqual(DateWheelTestHost.all(UIDatePicker.self, in: view).count, 1, "the harness can see the sheet's wheel")
        // `layer.render(in:)`, redrawn into a known RGBA bitmap: `drawHierarchy` reads SwiftUI back blank in a package test.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { ctx in view.layer.render(in: ctx.cgContext) }
        guard let cg = image.cgImage else { XCTFail("no pixels"); return Ink(fill: 0, brightest: 0, darkest: 0) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func luma(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let o = (Int(y) * w + Int(x)) * 4
            let r = 0.299 * CGFloat(px[o]), g = 0.587 * CGFloat(px[o + 1]), b = 0.114 * CGFloat(px[o + 2])
            return (r + g + b) / 255
        }
        // The selected row, the one the user reads while choosing, found from the wheel's own frame. Not the rows above and
        // below it: `layer.render(in:)` draws the wheel's fade masks as opaque gradients over them.
        guard let wheel = DateWheelTestHost.all(UIDatePicker.self, in: view).first else { return Ink(fill: 0, brightest: 0, darkest: 0) }
        let frame = wheel.convert(wheel.bounds, to: view)
        var brightest: CGFloat = 0, darkest: CGFloat = 1
        for y in stride(from: frame.midY - 10, to: frame.midY + 10, by: 1) {
            for x in stride(from: frame.minX + 10, to: frame.maxX - 10, by: 1) {
                let l = luma(x, y); brightest = max(brightest, l); darkest = min(darkest, l)
            }
        }
        return Ink(fill: luma(4, 4), brightest: brightest, darkest: darkest)
    }

    func testOnAPhoneInDarkTheSheetIsDarkAndItsRowsLight() {
        let i = ink(scheme: .dark, phone: .dark)
        XCTAssertLessThan(i.fill, 0.2, "the sheet is dark: \(i)")
        XCTAssertGreaterThan(i.brightest, 0.7, "a light date on the dark sheet: \(i)")
    }

    func testTheControlOnAPhoneInLightTheSheetIsLightAndItsRowsDark() {
        let i = ink(scheme: .light, phone: .light)
        XCTAssertGreaterThan(i.fill, 0.9, "the sheet is light: \(i)")
        XCTAssertLessThan(i.darkest, 0.3, "a dark date on the light sheet: \(i)")
    }

    func testAnAuthoredDarkSchemeOnAPhoneInLightPaintsTheSheetDarkToo() {
        let i = ink(scheme: .dark, phone: .light)
        XCTAssertLessThan(i.fill, 0.2, "the sheet follows the wheel's scheme, not the phone: \(i)")
        XCTAssertGreaterThan(i.brightest, 0.7, "a light date on the dark sheet: \(i)")
    }

    // MARK: - Which scheme the field hands its sheet

    /// Taps the compact field and returns the sheet it presents.
    private func presentedSheet(_ extra: [String: Any] = [:], background: String, phone: ColorScheme) throws -> CompactDateSheet? {
        var json: [String: Any] = ["picker_mode": NSNull(), "field_config": ["picker_variant": "compact"]]
        extra.forEach { json[$0.key] = $0.value }
        let block = try DateWheelTestHost.block(json, type: "input_date")
        let store = DateWheelTestHost.Store()
        let binding = Binding<[String: Any]>(get: { store.inputs }, set: { store.inputs = $0 })
        let hosting = host.show(FormInputDateBlock(block: block, inputValues: binding, components: .date), background: background, scheme: phone)
        guard let field = Self.elements(hosting.view).first(where: { $0.accessibilityTraits.contains(.button) }) else {
            XCTFail("no field button"); return nil
        }
        _ = field.accessibilityActivate()
        let end = Date().addingTimeInterval(4)
        while hosting.presentedViewController == nil && Date() < end { host.settle(0.05) }
        guard let presented = hosting.presentedViewController as? UIHostingController<AnyView> else {
            XCTFail("the field presented no sheet: \(String(describing: hosting.presentedViewController))"); return nil
        }
        func find(_ value: Any, _ depth: Int) -> CompactDateSheet? {
            if let sheet = value as? CompactDateSheet { return sheet }
            guard depth < 40 else { return nil }
            for child in Mirror(reflecting: value).children { if let f = find(child.value, depth + 1) { return f } }
            return nil
        }
        return find(presented.rootView, 0)
    }

    /// Through `A11yTree`, which recovers the tree when another process turns automation off.
    private static func elements(_ root: UIView) -> [NSObject] { A11yTree.read([root]) }

    func testAnUnstyledFieldOnALightStepHandsAPhoneInDarkADarkSheet() throws {
        XCTAssertEqual(try presentedSheet(background: "#FFFFFF", phone: .dark)?.scheme, .dark)
    }

    func testAnUnstyledFieldOnADarkStepHandsAPhoneInLightALightSheet() throws {
        XCTAssertEqual(try presentedSheet(background: "#111827", phone: .light)?.scheme, .light)
    }

    func testAnAuthoredDarkSchemeWinsOverAPhoneInLight() throws {
        XCTAssertEqual(try presentedSheet(["field_config": ["picker_variant": "compact", "color_scheme": "dark"]],
                                          background: "#FFFFFF", phone: .light)?.scheme, .dark)
    }
}

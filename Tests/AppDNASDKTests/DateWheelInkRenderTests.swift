import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// The wheel's unselected rows take their ink from the surface the block sits on, as the other unstyled controls do, in
/// either phone appearance. THE CONTROL: on a light step the same rows are dark, so a pass is not a wheel that is always
/// drawn light.
final class DateWheelInkRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    /// The brightness of every row that is not in the band, across the three columns.
    private func rowBrightness(_ view: UIView) -> [CGFloat] {
        DateWheelTestHost.all(WheelScrollView.self, in: view).flatMap { wheel in
            DateWheelTestHost.all(UILabel.self, in: wheel).compactMap { label -> CGFloat? in
                guard let colour = label.textColor, label.text != wheel.accessibilityValue else { return nil }
                var white: CGFloat = 0, alpha: CGFloat = 0
                colour.resolvedColor(with: label.traitCollection).getWhite(&white, alpha: &alpha)
                return white
            }
        }
    }

    private func show(on background: String, scheme: ColorScheme) throws -> [CGFloat] {
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: .init(),
                                  background: background, scheme: scheme).view!
        let rows = rowBrightness(view)
        XCTAssertGreaterThan(rows.count, 20, "the harness can see the rows")
        return rows
    }

    func testRowsAreLightOnADarkStepWithThePhoneInLight() throws {
        let rows = try show(on: "#111827", scheme: .light)
        XCTAssertTrue(rows.allSatisfy { $0 > 0.8 }, "dark rows on a dark step: \(Set(rows))")
    }

    func testRowsAreLightOnADarkStepWithThePhoneInDark() throws {
        let rows = try show(on: "#111827", scheme: .dark)
        XCTAssertTrue(rows.allSatisfy { $0 > 0.8 }, "dark rows on a dark step: \(Set(rows))")
    }

    func testTheControlRowsAreDarkOnALightStepWithThePhoneInDark() throws {
        let rows = try show(on: "#FFFFFF", scheme: .dark)
        XCTAssertTrue(rows.allSatisfy { $0 < 0.2 }, "light rows on a light step: \(Set(rows))")
    }

    func testAnAuthoredWheelTextColourStillWins() throws {
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15", "text_color": "#000000"]), store: .init(),
                                  background: "#111827", scheme: .dark).view!
        XCTAssertTrue(rowBrightness(view).allSatisfy { $0 < 0.2 })
    }
}

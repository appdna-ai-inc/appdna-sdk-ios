import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// A date block draws no picker but the one the user operates: the UIKit wheel that was mounted to warm UIKit up drew its
/// selected row, today's date, faintly beside the field. THE CONTROL: a calendar the themed wheel does not number keeps
/// UIKit's wheel, and the harness counts it, so zero is not a harness that cannot see a UIKit picker.
final class DatePickerPrewarmRenderTests: XCTestCase {
    private let host = DateWheelTestHost()
    override func tearDown() { host.tearDown(); super.tearDown() }

    private func pickers(_ view: UIView) -> Int { DateWheelTestHost.all(UIDatePicker.self, in: view).count }

    func testTheThemedWheelMountsNoUIKitPicker() throws {
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: .init()).view!
        XCTAssertEqual(pickers(view), 0)
    }

    func testAClosedFieldMountsNoUIKitPicker() throws {
        let view = host.showWheel(try DateWheelTestHost.block(["picker_presentation": "field", "default_date_value": "2000-06-15"]), store: .init()).view!
        XCTAssertEqual(pickers(view), 0)
    }

    func testACompactDateInputMountsNoUIKitPicker() throws {
        for (type, components) in [("input_date", DatePickerComponents.date), ("input_time", .hourAndMinute)] {
            let block = try DateWheelTestHost.block(["picker_mode": NSNull(), "field_config": ["picker_variant": "compact"]], type: type)
            let store = DateWheelTestHost.Store()
            let binding = Binding<[String: Any]>(get: { store.inputs }, set: { store.inputs = $0 })
            let view = host.show(FormInputDateBlock(block: block, inputValues: binding, components: components)).view!
            XCTAssertEqual(pickers(view), 0, type)
        }
    }

    func testUIKitsPickerIsStillWarmedForTheFirstDrag() throws {
        _ = host.showWheel(try DateWheelTestHost.block(["picker_presentation": "field"]), store: .init())
        XCTAssertTrue(DatePickerPrewarmer.hasRun)
    }

    func testTheControlANativeWheelIsCounted() throws {
        var japanese = Calendar(identifier: .japanese)
        japanese.locale = Locale(identifier: "en_US")
        let view = host.showWheel(try DateWheelTestHost.block(["default_date_value": "2000-06-15"]), store: .init(), calendar: japanese).view!
        XCTAssertGreaterThanOrEqual(pickers(view), 1)
    }
}

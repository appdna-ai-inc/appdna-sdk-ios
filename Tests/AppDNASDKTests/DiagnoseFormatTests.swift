import XCTest
@testable import AppDNASDK

/// `diagnose()` reports the veto wait as given. NEGATIVE CONTROL: it printed `Int(vetoTimeout)`, so a
/// 0.5 s wait read "0s".
final class DiagnoseFormatTests: XCTestCase {
    func testSecondsAreReportedAsGiven() {
        XCTAssertEqual(DiagnoseFormat.seconds(0.5), "0.5")
        XCTAssertEqual(DiagnoseFormat.seconds(2.7), "2.7")
        XCTAssertEqual(DiagnoseFormat.seconds(5), "5")
        XCTAssertEqual(DiagnoseFormat.seconds(8.0), "8")
    }
}

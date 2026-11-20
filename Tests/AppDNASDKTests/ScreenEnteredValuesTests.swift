import XCTest
@testable import AppDNASDK

/// A value entered in a Screen's content block reaches the host: a single screen collects it for
/// `ScreenResult.responses`, a flow for `FlowResult.responses`. Mirrors Android `ScreenContentBlocksComposeTest`.
final class ScreenEnteredValuesTests: XCTestCase {

    func testASingleScreenCollectsAndClearsEnteredValues() {
        let entered = ScreenManager.EnteredValues()
        let ctx = SectionContext(screenId: "scr", onAction: { _ in }, onResponse: { k, v in entered.set(k, v) })
        ctx.onResponse("nickname", "Robin")
        ctx.onResponse("opt_in", true)
        XCTAssertEqual(entered.values["nickname"] as? String, "Robin")
        XCTAssertEqual(entered.values["opt_in"] as? Bool, true)
        ctx.onResponse("opt_in", nil)
        XCTAssertNil(entered.values["opt_in"])
    }

    func testAFlowsResultCarriesEnteredValues() throws {
        let json = #"{"id":"f","name":"F","start_screen_id":"a","screens":[{"screen_id":"a","navigation_rules":[]}],"settings":{}}"#
        let flow = try JSONDecoder().decode(FlowConfig.self, from: Data(json.utf8))
        let fm = FlowManager(flowConfig: flow, screens: [:])
        var result: FlowResult?
        fm.onComplete = { result = $0 }
        fm.setEnteredValue("nickname", "Robin")
        fm.handleAction(.complete)
        XCTAssertEqual(result?.responses["nickname"] as? String, "Robin")
    }
}

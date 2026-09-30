import XCTest
import UserNotifications
@testable import AppDNASDK

/// SPEC-497 §17 item 28 — the console's action buttons show on iOS: the server sends each button set
/// under its own `aps.category`, the SDK registers that category (in the Notification Service Extension
/// before display, and whenever the app sees the push), a `text_reply` button is a text-input action,
/// and the typed text reaches the host as `data["reply_text"]`.
final class PushActionCategoryTests: XCTestCase {

    private func userInfo(category: String? = "appdna_abc", labels: [String] = ["View", "Later"]) -> [AnyHashable: Any] {
        var aps: [String: Any] = ["alert": ["title": "T", "body": "B"], "mutable-content": 1]
        if let category { aps["category"] = category }
        return [
            "aps": aps,
            "appdna": "1",
            "push_id": "p1",
            "actions": [
                ["id": "view", "label": labels[0], "action_type": "open_url", "action_value": "https://example.test/p", "foreground": true],
                ["id": "later", "label": labels[1], "action_type": "dismiss", "foreground": false],
                ["id": "reply", "label": "Reply", "action_type": "text_reply", "action_value": "Type a reply", "foreground": false],
            ],
        ]
    }

    func testCategoryIdIsApsCategory() {
        XCTAssertEqual(PushActionCategories.categoryId(from: userInfo()), "appdna_abc")
        XCTAssertEqual(PushActionCategories.categoryId(from: userInfo(category: nil)), "appdna_default")
    }

    func testButtonsMapToActions() throws {
        let category = try XCTUnwrap(PushActionCategories.category(from: userInfo()))
        XCTAssertEqual(category.actions.map(\.identifier), ["view", "later", "reply"])
        XCTAssertTrue(category.actions[0].options.contains(.foreground))
        XCTAssertFalse(category.actions[1].options.contains(.foreground))
        XCTAssertTrue(category.actions[1].options.contains(.destructive), "dismiss is destructive")
        let reply = try XCTUnwrap(category.actions[2] as? UNTextInputNotificationAction)
        XCTAssertEqual(reply.textInputPlaceholder, "Type a reply")
    }

    func testNoButtonsRegistersNothing() {
        let slot = InMemoryNotificationCenterSlot()
        PushActionCategories.register(from: ["aps": ["category": "x"], "appdna": "1"], slot: slot)
        XCTAssertTrue(slot.categories.isEmpty)
    }

    /// A re-registration with the same id replaces the old category; other categories (the host's) stay.
    func testRegisterReplacesSameIdAndKeepsOthers() throws {
        let slot = InMemoryNotificationCenterSlot()
        slot.setCategories([UNNotificationCategory(identifier: "HOST_CAT", actions: [], intentIdentifiers: [], options: [])])
        PushActionCategories.register(from: userInfo(labels: ["View", "Later"]), slot: slot)
        PushActionCategories.register(from: userInfo(labels: ["Open", "Skip"]), slot: slot)
        XCTAssertEqual(Set(slot.categories.map(\.identifier)), ["HOST_CAT", "appdna_abc"])
        let ours = try XCTUnwrap(slot.categories.first { $0.identifier == "appdna_abc" })
        XCTAssertEqual(ours.actions.map(\.title), ["Open", "Skip", "Reply"])
    }

    /// The extension waits for the category to be registered before it hands the content back.
    func testServiceExtensionRegistersBeforeCompleting() {
        let slot = InMemoryNotificationCenterSlot()
        var registeredAtCompletion: Set<String>?
        NotificationService.registerActionCategory(from: userInfo(), slot: slot) {
            registeredAtCompletion = Set(slot.categories.map(\.identifier))
        }
        XCTAssertEqual(registeredAtCompletion, ["appdna_abc"])

        var completedWithoutButtons = false
        NotificationService.registerActionCategory(from: ["aps": [String: Any]()], slot: slot) { completedWithoutButtons = true }
        XCTAssertTrue(completedWithoutButtons)
    }

    /// The typed reply of a text_reply button reaches the host as data["reply_text"].
    func testReplyTextReachesPayloadData() {
        var info = userInfo()
        info[PushReply.userInfoKey] = "See you there"
        let payload = PushPayloadParser.parse(userInfo: info, title: "T", body: "B")
        XCTAssertEqual(payload.data?[PushReply.dataKey] as? String, "See you there")
        XCTAssertNil(PushPayloadParser.parse(userInfo: userInfo(), title: "T", body: "B").data?[PushReply.dataKey])
    }

    /// Tapping the open_url button routes the button's URL through the deep-link handler (rung 0);
    /// tapping dismiss or reply routes nowhere.
    func testButtonTapRouting() {
        let info = userInfo()
        let payload = PushPayloadParser.parse(userInfo: info, title: "T", body: "B")
        XCTAssertEqual(PushTapRouter.route(payload: payload, userInfo: info, tappedActionId: "view"), .deepLink("https://example.test/p"))
        XCTAssertEqual(PushTapRouter.route(payload: payload, userInfo: info, tappedActionId: "later"), .ignored)
        XCTAssertEqual(PushTapRouter.route(payload: payload, userInfo: info, tappedActionId: "reply"), .ignored)
    }
}

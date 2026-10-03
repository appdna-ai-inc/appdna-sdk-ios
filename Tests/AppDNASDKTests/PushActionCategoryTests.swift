import XCTest
import UserNotifications
@testable import AppDNASDK
@_spi(AppDNAInternal) @testable import AppDNANotificationExtension

/// The console's action buttons show on iOS: the server sends each button set
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
        AppDNANotificationExtension.NotificationService.registerActionCategory(from: userInfo(), slot: slot) {
            registeredAtCompletion = Set(slot.categories.map(\.identifier))
        }
        XCTAssertEqual(registeredAtCompletion, ["appdna_abc"])

        var completedWithoutButtons = false
        AppDNANotificationExtension.NotificationService.registerActionCategory(from: ["aps": [String: Any]()], slot: slot) { completedWithoutButtons = true }
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

    // MARK: -

    /// NEGATIVE CONTROL: a `dismiss` button sent with `foreground: true` got `[.foreground, .destructive]`,
    /// so tapping "Dismiss" launched the app.
    func testDismissWithForegroundTrueNeverOpensTheApp() throws {
        var info = userInfo()
        info["actions"] = [["id": "close", "label": "Close", "action_type": "dismiss", "foreground": true]]
        let action = try XCTUnwrap(PushActionCategories.category(from: info)?.actions.first)
        XCTAssertEqual(action.options, [.destructive])
        XCTAssertFalse(action.options.contains(.foreground))
    }

    /// A slot whose reads answer later, on another queue — as the real centre does.
    final class AsyncSlot: NotificationCenterSlot {
        private let lock = NSLock()
        private var stored: Set<UNNotificationCategory> = []
        var categories: Set<UNNotificationCategory> { lock.lock(); defer { lock.unlock() }; return stored }
        var delegate: UNUserNotificationCenterDelegate?
        func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) {
            let snapshot = categories
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { completion(snapshot) }
        }
        func setCategories(_ categories: Set<UNNotificationCategory>) { lock.lock(); stored = categories; lock.unlock() }
        func deliveredCategoryIds(_ completion: @escaping (Set<String>) -> Void) { completion([]) }
        func add(_ request: UNNotificationRequest) {}
    }

    /// NEGATIVE CONTROL: two overlapping registrations both read the empty set, and the second write
    /// dropped the first one's category (one id registered instead of two).
    func testOverlappingRegistrationsKeepBothCategories() {
        let slot = AsyncSlot()
        let both = expectation(description: "both registered")
        both.expectedFulfillmentCount = 2
        PushActionCategories.register(from: userInfo(category: "appdna_one"), slot: slot) { both.fulfill() }
        PushActionCategories.register(from: userInfo(category: "appdna_two"), slot: slot) { both.fulfill() }
        wait(for: [both], timeout: 3)
        XCTAssertEqual(Set(slot.categories.map(\.identifier)), ["appdna_one", "appdna_two"])
    }

    /// The other process (the Notification Service Extension, or the app) as the centre sees it: right
    /// after this process's `clobberOnWrite`-th write it writes the set IT read before that write, plus its
    /// own category — so this process's category is dropped. `RegistrationQueue` cannot serialise that.
    final class OtherProcessSlot: NotificationCenterSlot {
        private(set) var categories: Set<UNNotificationCategory> = []
        var delegate: UNUserNotificationCenterDelegate?
        let otherCategory: UNNotificationCategory
        var clobberOnWrite: Set<Int>
        private var writes = 0
        init(other: String, clobberOnWrite: Set<Int>) {
            otherCategory = UNNotificationCategory(identifier: other, actions: [], intentIdentifiers: [], options: [])
            self.clobberOnWrite = clobberOnWrite
        }
        func getCategories(_ completion: @escaping (Set<UNNotificationCategory>) -> Void) { completion(categories) }
        func setCategories(_ new: Set<UNNotificationCategory>) {
            let before = categories
            writes += 1
            categories = new
            if clobberOnWrite.contains(writes) { categories = before.union([otherCategory]) }
        }
        func deliveredCategoryIds(_ completion: @escaping (Set<String>) -> Void) { completion([]) }
        func add(_ request: UNNotificationRequest) {}
    }

    /// NEGATIVE CONTROL: the registration wrote once and trusted it, so the other process's write — built
    /// from a set read before ours — dropped `appdna_ours` and only `appdna_theirs` stayed registered.
    func testAnotherProcessesOverlappingWriteIsReMerged() {
        let slot = OtherProcessSlot(other: "appdna_theirs", clobberOnWrite: [])
        slot.setCategories([UNNotificationCategory(identifier: "HOST_CAT", actions: [], intentIdentifiers: [], options: [])])
        slot.clobberOnWrite = [2] // the first write above was the host's seed
        PushActionCategories.register(from: userInfo(category: "appdna_ours"), slot: slot)
        XCTAssertEqual(Set(slot.categories.map(\.identifier)), ["HOST_CAT", "appdna_ours", "appdna_theirs"])
    }

    /// The re-check is bounded: a centre that drops the category on every write ends the registration
    /// after `maxReMergeAttempts` re-merges (it still completes).
    func testReMergeIsBounded() {
        let max = PushActionCategories.maxReMergeAttempts
        let slot = OtherProcessSlot(other: "appdna_theirs", clobberOnWrite: Set(1...(max + 5)))
        var completed = 0
        PushActionCategories.register(from: userInfo(category: "appdna_ours"), slot: slot) { completed += 1 }
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(slot.categories.contains { $0.identifier == "appdna_ours" }, "the documented remaining race")
    }

    /// The extension (no SDK context) and the app (the user's context) must register the same titles.
    /// NEGATIVE CONTROL: the app interpolated with its own context, so the same category read
    /// "Hi Ada" from the app and "Hi there" from the extension.
    func testButtonTitlesDoNotDependOnTheAppContext() throws {
        SessionDataStore.shared.setSessionData(key: "r18_name", value: "Ada")
        defer { SessionDataStore.shared.clearSessionData() }
        var info = userInfo()
        info["actions"] = [["id": "hi", "label": "Hi {{session.r18_name | there}}", "action_type": "deep_link",
                            "action_value": "app://x", "foreground": true]]
        let action = try XCTUnwrap(PushActionCategories.category(from: info)?.actions.first)
        XCTAssertEqual(action.title, "Hi there")
        // The host's payload is still personalised.
        XCTAssertEqual(PushPayloadParser.parse(userInfo: info, title: "T", body: "B").actions.first?.label, "Hi Ada")
    }

    /// NEGATIVE CONTROL: every distinct button set stayed registered forever (17 categories here).
    func testRegisteredCategoriesArePruned() {
        let suite = "ai.appdna.sdk.test.push.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = PushActionCategories.recencyDefaults
        PushActionCategories.recencyDefaults = defaults
        defer { PushActionCategories.recencyDefaults = previous; defaults.removePersistentDomain(forName: suite) }

        let slot = InMemoryNotificationCenterSlot()
        slot.setCategories([UNNotificationCategory(identifier: "HOST_CAT", actions: [], intentIdentifiers: [], options: [])])
        slot.delivered = ["appdna_0"]
        let max = PushActionCategories.maxRegisteredCategories
        for i in 0...max { PushActionCategories.register(from: userInfo(category: "appdna_\(i)"), slot: slot) }
        let ids = Set(slot.categories.map(\.identifier))
        XCTAssertEqual(ids.filter { $0.hasPrefix("appdna_") }.count, max, "at most \(max) of ours")
        XCTAssertTrue(ids.contains("HOST_CAT"), "the host's category is never pruned")
        XCTAssertTrue(ids.contains("appdna_0"), "a delivered notification's category is kept")
        XCTAssertTrue(ids.contains("appdna_\(max)"), "the new one is kept")
        XCTAssertFalse(ids.contains("appdna_1"), "the oldest undelivered one goes")
    }

    /// NEGATIVE CONTROL: the time-out handed the content back and the download, finishing later, handed
    /// it back again — the content handler ran twice.
    func testServiceExtensionHandsTheContentBackOnce() {
        // Both public classes: `NotificationService` and the older `AppDNANotificationService`, which had
        // its own copy of the same double hand-back (it is a subclass now).
        handsTheContentBackOnce(AppDNANotificationExtension.NotificationService())
        handsTheContentBackOnce(AppDNANotificationExtension.AppDNANotificationService())
    }

    private func handsTheContentBackOnce(_ service: AppDNANotificationExtension.NotificationService) {
        var pendingLoad: ((UNNotificationAttachment?) -> Void)?
        service.attachmentLoader = { _, done in pendingLoad = done }
        let content = UNMutableNotificationContent()
        content.userInfo = ["appdna": "1", "image_url": "https://example.test/i.png"]
        var handed = 0
        service.didReceive(UNNotificationRequest(identifier: "r", content: content, trigger: nil)) { _ in handed += 1 }
        XCTAssertEqual(handed, 0, "waiting for the download")
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(handed, 1)
        pendingLoad?(nil)
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(handed, 1, "the content handler runs once")
    }

    /// `buttonTitle` re-implements `TemplateEngine.interpolate` with an empty context (the extension module
    /// cannot link the engine). Pinned against the engine itself.
    func testButtonTitleMatchesTheTemplateEngineWithAnEmptyContext() {
        let empty = TemplateContext(userTraits: nil, remoteConfig: { _ in nil }, onboardingResponses: [:],
                                    computedData: [:], sessionData: [:], deviceInfo: [:])
        for raw in ["Plain", "Hi {{user.name | there}}", "{{x}}!", "{{ a.b |  fb  }} and {{c|d}}", "{{broken", "{{}}"] {
            XCTAssertEqual(PushActionCategories.buttonTitle(raw), TemplateEngine.shared.interpolate(raw, context: empty), raw)
        }
    }

    /// Icons map through the shared table, so the extension and the app pick the same SF Symbol.
    func testIconTablesAreShared() {
        XCTAssertEqual(IconMapping.lucideToSFSymbol, SFSymbolTables.lucide)
        XCTAssertEqual(IconMapping.materialToSFSymbol, SFSymbolTables.material)
        XCTAssertEqual(SFSymbolTables.lucide["check"], "checkmark")
    }
}

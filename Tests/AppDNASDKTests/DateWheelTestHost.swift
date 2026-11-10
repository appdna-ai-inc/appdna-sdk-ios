import SwiftUI
import UIKit
import XCTest
@testable import AppDNASDK

/// A date block in a real key window, and the readers the date wheel tests share.
final class DateWheelTestHost {
    final class Store { var inputs: [String: Any] = [:] }

    private(set) var windows: [UIWindow] = []

    func tearDown() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
    }

    static func block(_ extra: [String: Any] = [:], type: String = "date_wheel_picker") throws -> ContentBlock {
        var json: [String: Any] = ["id": "w", "type": type, "field_id": "born", "picker_mode": "date", "highlight_color": "#FF0000",
                                   "wheel_height": 200, "field_config": ["picker_variant": "wheel"]]
        extra.forEach { json[$0.key] = $0.value }
        return try JSONDecoder().decode(ContentBlock.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// `content` on `background`, in the surface environment a step sets for the blocks it draws.
    func show<V: View>(_ content: V, background: String = "#FFFFFF", scheme: ColorScheme = .light,
                       calendar: Calendar = Calendar(identifier: .gregorian)) -> UIHostingController<AnyView> {
        let root = AnyView(content
            .environment(\.calendar, calendar)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.googleAttributionBackdrop, .plain(hex: background))
            .frame(width: 360, height: 300)
            .background(Color(hex: background))
            .environment(\.colorScheme, scheme))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        windows.append(window)
        settle()
        host.view.layoutIfNeeded()
        settle(0.3)
        return host
    }

    func showWheel(_ block: ContentBlock, store: Store, background: String = "#FFFFFF", scheme: ColorScheme = .light,
                   calendar: Calendar = Calendar(identifier: .gregorian)) -> UIHostingController<AnyView> {
        let binding = Binding<[String: Any]>(get: { store.inputs }, set: { store.inputs = $0 })
        return show(DateWheelPickerBlockView(block: block, inputValues: binding), background: background, scheme: scheme, calendar: calendar)
    }

    func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var out: [T] = []
        func walk(_ v: UIView) { if let t = v as? T { out.append(t) }; v.subviews.forEach(walk) }
        walk(view)
        return out
    }

    static func wheel(_ name: String, in view: UIView) -> WheelScrollView? {
        all(WheelScrollView.self, in: view).first { $0.accessibilityLabel == name }
    }
}

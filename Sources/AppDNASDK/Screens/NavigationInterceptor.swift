import UIKit

/// Intercepts UIViewController lifecycle to inject server-driven screens between navigations.
/// Only active when `AppDNA.enableNavigationInterception()` is called.
internal class NavigationInterceptor {
    static let shared = NavigationInterceptor()

    private var isEnabled = false
    private var swizzled = false

    func enable() {
        guard !swizzled else { return }
        swizzleViewDidAppear()
        isEnabled = true
        swizzled = true
    }

    func disable() {
        isEnabled = false
        // Note: swizzle stays in place but evaluateInterceptions returns early when disabled
    }

    private func swizzleViewDidAppear() {
        let originalSelector = #selector(UIViewController.viewDidAppear(_:))
        let swizzledSelector = #selector(UIViewController.appdna_viewDidAppear(_:))

        guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIViewController.self, swizzledSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    func onViewControllerDidAppear(_ viewController: UIViewController) {
        guard isEnabled else { return }
        guard AppDNA.isConsentGranted() else { return }

        // Skip SDK-internal view controllers
        let className = String(describing: type(of: viewController))
        if className.hasPrefix("AppDNA") || className.hasPrefix("Screen") || className.contains("Hosting") {
            return
        }

        // Evaluate "after" timing interceptions
        ScreenManager.shared.evaluateInterceptions(screenName: className, timing: "after")
        // `on_screen` screen triggers, evaluated where the "after" interceptions are.
        ScreenManager.shared.onScreenAppeared(className)
    }
}

// MARK: - UIViewController Swizzle Extension

extension UIViewController {
    @objc func appdna_viewDidAppear(_ animated: Bool) {
        // Call original implementation (swizzled)
        self.appdna_viewDidAppear(animated)

        // Notify interceptor
        NavigationInterceptor.shared.onViewControllerDidAppear(self)
    }
}

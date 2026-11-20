import SwiftUI
import UIKit

/// Handles presenting server-driven screens in different modes (fullscreen, modal, bottom_sheet, push).
internal class ScreenPresenter {

    static func present(
        config: ScreenConfig,
        context: SectionContext,
        from viewController: UIViewController? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        let contextHolder = ScreenContextHolder(context: context)
        let renderer = ScreenRenderer(config: config, context: contextHolder)
        let hostingController = ScreenHostingController(rootView: AnyView(renderer), onDismiss: onDismiss)

        switch config.presentation ?? "modal" {
        case "fullscreen":
            hostingController.modalPresentationStyle = .fullScreen
            hostingController.modalTransitionStyle = transitionStyle(config.transition)

        case "modal":
            hostingController.modalPresentationStyle = .pageSheet

        case "bottom_sheet":
            hostingController.modalPresentationStyle = .pageSheet
            if #available(iOS 15.0, *) {
                if let sheet = hostingController.sheetPresentationController {
                    sheet.detents = [.medium(), .large()]
                    sheet.prefersGrabberVisible = true
                }
            }

        case "push":
            if let navController = viewController?.navigationController {
                navController.pushViewController(hostingController, animated: true)
                return
            }
            // Fallback to modal if no nav controller
            hostingController.modalPresentationStyle = .fullScreen

        default:
            hostingController.modalPresentationStyle = .fullScreen
        }

        let presentBlock = {
            let presenter = viewController ?? UIApplication.shared.topViewController
            presenter?.present(hostingController, animated: true)
        }
        if Thread.isMainThread {
            presentBlock()
        } else {
            DispatchQueue.main.async { presentBlock() }
        }
    }

    /// 🔴 THIS PRESENTED THE FIRST SCREEN AND NEVER MOVED.
    ///
    /// It read `flowManager.currentScreen` ONCE, built a `SectionContext` from that snapshot, and handed
    /// the resulting `ScreenRenderer` to `present(config:context:)`. So `handleAction` advanced
    /// `currentScreenIndex` — and nothing re-rendered. A multi-screen flow showed screen 1 forever and
    /// "Next" was a dead button.
    ///
    /// `FlowManager` was an `ObservableObject` with `@Published var currentScreenIndex` the whole time.
    /// The observability existed; the view simply never observed it. `FlowHostView` does.
    static func presentFlow(
        flowManager: FlowManager,
        from viewController: UIViewController? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        guard flowManager.currentScreen != nil else { return }

        let host = FlowHostView(flowManager: flowManager)
        let hostingController = ScreenHostingController(rootView: AnyView(host), onDismiss: onDismiss)

        // The flow's presentation style comes from its FIRST screen, as before.
        switch flowManager.currentScreen?.presentation ?? "modal" {
        case "fullscreen":
            hostingController.modalPresentationStyle = .fullScreen
            hostingController.modalTransitionStyle = transitionStyle(flowManager.currentScreen?.transition)
        case "bottom_sheet":
            hostingController.modalPresentationStyle = .pageSheet
        default:
            hostingController.modalPresentationStyle = .pageSheet
        }

        guard let presenter = viewController ?? AppDNA.topViewController() else { return }
        presenter.present(hostingController, animated: true)
    }

    private static func transitionStyle(_ transition: String?) -> UIModalTransitionStyle {
        switch transition {
        case "slide_up": return .coverVertical
        case "slide_left": return .coverVertical // iOS doesn't have native slide-left modal
        case "fade": return .crossDissolve
        case "none": return .crossDissolve
        default: return .coverVertical
        }
    }
}

// MARK: - Hosting Controller with dismiss callback

private class ScreenHostingController: UIHostingController<AnyView> {
    var onDismiss: (() -> Void)?

    init(rootView: AnyView, onDismiss: (() -> Void)?) {
        self.onDismiss = onDismiss
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            onDismiss?()
            PresentationCoordinator.shared.onDismissed()
        }
    }
}

// MARK: - UIApplication extension for top view controller

extension UIApplication {
    var topViewController: UIViewController? {
        guard let windowScene = connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else { return nil }

        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}


/// Re-renders whenever the flow advances. See `ScreenPresenter.presentFlow`.
private struct FlowHostView: View {
    @ObservedObject var flowManager: FlowManager

    var body: some View {
        if let config = flowManager.currentScreen {
            ScreenRenderer(
                config: config,
                context: ScreenContextHolder(
                    context: SectionContext(
                        screenId: flowManager.currentScreenId ?? "",
                        flowId: flowManager.flowConfig.id,
                        responses: flowManager.responses,
                        onAction: { [weak flowManager] action in
                            flowManager?.handleAction(action)
                        },
                        // Entered values join the flow's responses (FlowResult.responses, navigation rules).
                        onResponse: { [weak flowManager] key, value in
                            flowManager?.setEnteredValue(key, value)
                        },
                        currentScreenIndex: flowManager.currentScreenIndex,
                        totalScreens: flowManager.flowConfig.screens?.count ?? 0
                    )
                )
            )
            // The screen id keys the identity, so SwiftUI tears down the old screen's state instead of
            // reusing it for the next one — otherwise a text field's contents would bleed across screens.
            .id(flowManager.currentScreenId ?? "\(flowManager.currentScreenIndex)")
        } else {
            EmptyView()
        }
    }
}

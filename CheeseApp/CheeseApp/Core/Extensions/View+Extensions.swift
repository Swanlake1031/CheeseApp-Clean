//
//  View+Extensions.swift
//  CheeseApp
//
//  🎯 View 扩展
//
import SwiftUI
import UIKit

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct KeyboardDismissPriorityModifier: ViewModifier {
    let isActive: Bool
    let dismissKeyboard: () -> Void

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!isActive)
            .overlay {
                if isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissKeyboard)
                }
            }
    }
}

private final class BackgroundKeyboardDismissMarkerView: UIView {
    var onWindowChange: ((BackgroundKeyboardDismissMarkerView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(self)
    }
}

private struct BackgroundKeyboardDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> BackgroundKeyboardDismissMarkerView {
        let marker = BackgroundKeyboardDismissMarkerView(frame: .zero)
        marker.isUserInteractionEnabled = false
        marker.onWindowChange = { [weak coordinator = context.coordinator] marker in
            coordinator?.installIfNeeded(from: marker)
        }
        return marker
    }

    func updateUIView(
        _ marker: BackgroundKeyboardDismissMarkerView,
        context: Context
    ) {
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: marker)
        }
    }

    static func dismantleUIView(
        _ marker: BackgroundKeyboardDismissMarkerView,
        coordinator: Coordinator
    ) {
        marker.onWindowChange = nil
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var marker: UIView?
        private weak var installedWindow: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(dismissKeyboard)
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        func installIfNeeded(from marker: UIView) {
            self.marker = marker
            guard let window = marker.window else {
                uninstallRecognizer()
                return
            }
            guard installedWindow !== window else { return }
            uninstall()
            self.marker = marker
            installedWindow = window
            window.addGestureRecognizer(recognizer)
        }

        func uninstall() {
            uninstallRecognizer()
            marker = nil
        }

        private func uninstallRecognizer() {
            installedWindow?.removeGestureRecognizer(recognizer)
            installedWindow = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let marker,
                  marker.window === installedWindow,
                  marker.bounds.contains(touch.location(in: marker))
            else { return false }

            var touchedView = touch.view
            while let view = touchedView {
                if view is UITextField || view is UITextView {
                    return false
                }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }
}

extension View {
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ViewHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: action)
    }

    func prioritizeKeyboardDismissal(
        while isActive: Bool,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(
            KeyboardDismissPriorityModifier(
                isActive: isActive,
                dismissKeyboard: onDismiss
            )
        )
    }
}
import ObjectiveC
@MainActor
final class CheeseTabBarVisibilityController: ObservableObject {
    static let shared = CheeseTabBarVisibilityController()

    @Published private var hiddenTokens: Set<UUID> = []

    var isHidden: Bool {
        !hiddenTokens.isEmpty
    }

    private init() {}

    func setHidden(_ hidden: Bool, token: UUID) {
        if hidden {
            hiddenTokens.insert(token)
        } else {
            hiddenTokens.remove(token)
        }
    }

    func resetVisibility() {
        hiddenTokens.removeAll()
    }
}
private final class CheeseTabBarVisibilityTokenBox: ObservableObject {
    let token = UUID()

    deinit {
        let token = self.token
        Task { @MainActor in
            CheeseTabBarVisibilityController.shared.setHidden(false, token: token)
        }
    }
}
private struct CheeseTabBarHiddenModifier: ViewModifier {
    let hidden: Bool
    @StateObject private var tokenBox = CheeseTabBarVisibilityTokenBox()

    func body(content: Content) -> some View {
        content
            .onAppear {
                CheeseTabBarVisibilityController.shared.setHidden(hidden, token: tokenBox.token)
            }
            .onChange(of: hidden) { _, newValue in
                CheeseTabBarVisibilityController.shared.setHidden(newValue, token: tokenBox.token)
            }
            .onDisappear {
                CheeseTabBarVisibilityController.shared.setHidden(false, token: tokenBox.token)
            }
    }
}

enum SwipeBackGesturePolicy {
    /// The native gesture used to require a nearly horizontal drag. Allow a
    /// natural diagonal gesture while still rejecting a predominantly vertical
    /// scroll. 1.8 means horizontal intent may be about 56% of vertical intent.
    static let verticalToleranceMultiplier: CGFloat = 1.8

    static func shouldBegin(
        viewControllerCount: Int,
        isTransitioning: Bool,
        velocity: CGPoint,
        translation: CGPoint = .zero
    ) -> Bool {
        guard viewControllerCount > 1, !isTransitioning else { return false }

        // Translation is more stable than instantaneous velocity when the
        // finger starts diagonally or jitters at the edge. Fall back to velocity
        // for the first recognition sample and for unit-level policy checks.
        let hasTranslationSample = hypot(translation.x, translation.y) > 1
        let direction = hasTranslationSample ? translation : velocity
        guard direction.x > 0 else { return false }

        return direction.x * verticalToleranceMultiplier >= abs(direction.y)
    }

    static func shouldIntercept(
        viewControllerCount: Int,
        isTransitioning: Bool,
        hasUnsavedChanges: Bool
    ) -> Bool {
        viewControllerCount > 1 && !isTransitioning && hasUnsavedChanges
    }

    static func shouldRecognizeSimultaneously(
        isInteractivePopGesture: Bool,
        isOtherPanGesture: Bool
    ) -> Bool {
        // Taps may coexist, but once an edge-pop is recognized no ScrollView,
        // carousel, image drag or other pan should continue moving underneath.
        isInteractivePopGesture && !isOtherPanGesture
    }

    static func shouldPrioritizeInteractivePop(
        isInteractivePopGesture: Bool,
        isOtherPanGesture: Bool
    ) -> Bool {
        isInteractivePopGesture && isOtherPanGesture
    }
}

private final class SwipeBackGestureDelegateProxy: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?
    private var interceptionOwnerID: UUID?
    private var hasUnsavedChanges = false
    private var onInterceptedSwipeBack: (() -> Void)?

    func registerInterception(
        ownerID: UUID,
        hasUnsavedChanges: Bool,
        onAttempt: @escaping () -> Void
    ) {
        guard hasUnsavedChanges else {
            clearInterception(ownerID: ownerID)
            return
        }
        interceptionOwnerID = ownerID
        self.hasUnsavedChanges = true
        onInterceptedSwipeBack = onAttempt
    }

    func clearInterception(ownerID: UUID) {
        guard interceptionOwnerID == ownerID else { return }
        interceptionOwnerID = nil
        hasUnsavedChanges = false
        onInterceptedSwipeBack = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }

        let viewControllerCount = navigationController.viewControllers.count
        let isTransitioning = navigationController.transitionCoordinator != nil
        if SwipeBackGesturePolicy.shouldIntercept(
            viewControllerCount: viewControllerCount,
            isTransitioning: isTransitioning,
            hasUnsavedChanges: hasUnsavedChanges
        ) {
            let action = onInterceptedSwipeBack
            DispatchQueue.main.async {
                action?()
            }
            return false
        }

        return SwipeBackGesturePolicy.shouldBegin(
            viewControllerCount: viewControllerCount,
            isTransitioning: isTransitioning,
            velocity: panGesture.velocity(in: panGesture.view),
            translation: panGesture.translation(in: panGesture.view)
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let isInteractivePopGesture =
            gestureRecognizer === navigationController?.interactivePopGestureRecognizer
        let isOtherPanGesture = otherGestureRecognizer is UIPanGestureRecognizer

        return SwipeBackGesturePolicy.shouldRecognizeSimultaneously(
            isInteractivePopGesture: isInteractivePopGesture,
            isOtherPanGesture: isOtherPanGesture
        )
    }

}

private enum SwipeBackAssociatedKeys {
    static var delegateProxy: UInt8 = 0
}

private extension UINavigationController {
    var cheeseSwipeBackDelegateProxy: SwipeBackGestureDelegateProxy {
        if let proxy = objc_getAssociatedObject(
            self,
            &SwipeBackAssociatedKeys.delegateProxy
        ) as? SwipeBackGestureDelegateProxy {
            return proxy
        }

        let proxy = SwipeBackGestureDelegateProxy()
        proxy.navigationController = self
        objc_setAssociatedObject(
            self,
            &SwipeBackAssociatedKeys.delegateProxy,
            proxy,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return proxy
    }
}

private final class SwipeBackGestureHostViewController: UIViewController {
    private let configuredCompetingPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    private weak var observedPopGesture: UIGestureRecognizer?

    var isSwipeBackEnabled = true {
        didSet { configureSwipeBackGesture() }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            stopObservingPopGesture()
        } else {
            configureSwipeBackGesture()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureSwipeBackGesture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        configureSwipeBackGesture()
    }

    func configureSwipeBackGesture() {
        guard let navigationController,
              let popGesture = navigationController.interactivePopGestureRecognizer else {
            return
        }

        let proxy = navigationController.cheeseSwipeBackDelegateProxy
        proxy.navigationController = navigationController
        observePopGesture(popGesture)

        // The system edge recognizer already supplies a finger-driven percent
        // transition, velocity completion and cancellation spring. Keeping it
        // preserves the native page-following behavior instead of dismissing
        // abruptly after a SwiftUI DragGesture ends.
        popGesture.cancelsTouchesInView = true
        popGesture.delaysTouchesBegan = false
        popGesture.delaysTouchesEnded = false
        popGesture.requiresExclusiveTouchType = true

        if let panGesture = popGesture as? UIPanGestureRecognizer {
            panGesture.maximumNumberOfTouches = 1
        }
        if let screenEdgeGesture = popGesture as? UIScreenEdgePanGestureRecognizer {
            screenEdgeGesture.edges = .left
        }

        // UIKit can reset this delegate as navigation destinations change. The
        // host is installed once per NavigationStack and reapplies the shared
        // policy during layout/appearance, without per-page gesture code.
        if popGesture.state == .possible, popGesture.delegate !== proxy {
            popGesture.delegate = proxy
        }

        // Leave it enabled at the root. shouldBegin rejects a one-controller
        // stack, while the recognizer is immediately ready after a push without
        // waiting for a detail view to install another modifier.
        popGesture.isEnabled = isSwipeBackEnabled
        guard isSwipeBackEnabled else { return }

        // A failure relationship must point from the competing pan to the edge
        // pop. The previous delegate callback expressed the reverse direction,
        // which let Forum board ScrollViews win. Away from the left edge the
        // screen-edge recognizer fails immediately, so ordinary scrolling and
        // horizontal components remain unaffected.
        for panGesture in navigationController.view.cheeseDescendantPanGestures
        where panGesture !== popGesture && configuredCompetingPans.member(panGesture) == nil {
            panGesture.require(toFail: popGesture)
            configuredCompetingPans.add(panGesture)
        }
    }

    private func observePopGesture(_ gesture: UIGestureRecognizer) {
        guard observedPopGesture !== gesture else { return }
        stopObservingPopGesture()
        observedPopGesture = gesture
        gesture.addTarget(self, action: #selector(handlePopGesture(_:)))
    }

    private func stopObservingPopGesture() {
        observedPopGesture?.removeTarget(self, action: #selector(handlePopGesture(_:)))
        observedPopGesture = nil
    }

    @objc private func handlePopGesture(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        navigationController?.view.endEditing(true)
    }
}

private extension UIView {
    var cheeseDescendantPanGestures: [UIPanGestureRecognizer] {
        let local = (gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
        return subviews.reduce(into: local) { result, subview in
            result.append(contentsOf: subview.cheeseDescendantPanGestures)
        }
    }
}

private struct SwipeBackGestureEnabler: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> SwipeBackGestureHostViewController {
        let controller = SwipeBackGestureHostViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(
        _ uiViewController: SwipeBackGestureHostViewController,
        context: Context
    ) {
        uiViewController.isSwipeBackEnabled = isEnabled
        DispatchQueue.main.async {
            uiViewController.configureSwipeBackGesture()
        }
    }
}

private final class SwipeBackInterceptionHostViewController: UIViewController {
    let ownerID = UUID()
    var hasUnsavedChanges = false
    var onAttempt: () -> Void = {}
    weak var registeredNavigationController: UINavigationController?

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            unregisterInterception()
        } else {
            updateInterception()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateInterception()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unregisterInterception()
    }

    func updateInterception() {
        guard let navigationController else {
            unregisterInterception()
            return
        }

        if registeredNavigationController !== navigationController {
            unregisterInterception()
            registeredNavigationController = navigationController
        }

        navigationController.cheeseSwipeBackDelegateProxy.registerInterception(
            ownerID: ownerID,
            hasUnsavedChanges: hasUnsavedChanges,
            onAttempt: onAttempt
        )
    }

    func unregisterInterception() {
        registeredNavigationController?
            .cheeseSwipeBackDelegateProxy
            .clearInterception(ownerID: ownerID)
        registeredNavigationController = nil
    }
}

private struct SwipeBackInterceptionGuard: UIViewControllerRepresentable {
    let hasUnsavedChanges: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> SwipeBackInterceptionHostViewController {
        let controller = SwipeBackInterceptionHostViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(
        _ uiViewController: SwipeBackInterceptionHostViewController,
        context: Context
    ) {
        uiViewController.hasUnsavedChanges = hasUnsavedChanges
        uiViewController.onAttempt = onAttempt
        DispatchQueue.main.async {
            uiViewController.updateInterception()
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: SwipeBackInterceptionHostViewController,
        coordinator: ()
    ) {
        uiViewController.unregisterInterception()
    }
}

extension View {
    
    /// 条件修饰符
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    /// 隐藏键盘
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 点击空白区域收起键盘
    func dismissKeyboardOnTap() -> some View {
        background(BackgroundKeyboardDismissInstaller())
    }
    
    /// 控制 MainTabView 的自定义底部导航显示
    func cheeseTabBarHidden(_ hidden: Bool) -> some View {
        modifier(CheeseTabBarHiddenModifier(hidden: hidden))
    }

    /// 统一启用原生左缘互动返回；应挂在 NavigationStack 根层。
    func enableSwipeBackGesture(_ isEnabled: Bool = true) -> some View {
        background(
            SwipeBackGestureEnabler(isEnabled: isEnabled)
                .frame(width: 0, height: 0)
        )
    }

    /// 有未保存内容时拦截左缘返回，交由页面显示保存／舍弃确认。
    func interceptSwipeBack(
        when hasUnsavedChanges: Bool,
        onAttempt: @escaping () -> Void
    ) -> some View {
        background(
            SwipeBackInterceptionGuard(
                hasUnsavedChanges: hasUnsavedChanges,
                onAttempt: onAttempt
            )
            .frame(width: 0, height: 0)
        )
    }

    /// 单行显示，超出尾部省略（...）
    func singleLineEllipsized() -> some View {
        lineLimit(1)
            .truncationMode(.tail)
    }
}

enum HapticEngine {
    private static let settingKey = "settings_haptic_feedback"

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    private static func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        runOnMain {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred(intensity: 1.0)
        }
    }

    static func selection() {
        guard isEnabled else { return }
        runOnMain {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
        }
    }
}

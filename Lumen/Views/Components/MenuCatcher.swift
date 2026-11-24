import SwiftUI
import UIKit

/// Takes the remote's Menu press for a page while `active`, wherever the focus is: without it
/// a press `onExitCommand` misses goes to the navigation, which pops the page. Nothing while
/// something is presented over the page (player, menu) or another page covers it.
struct MenuCatcher: UIViewRepresentable {
    let active: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> CatcherView { CatcherView() }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.active = active
        view.action = action
    }

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        var active = false
        var action: () -> Void = {}
        private lazy var menu: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(pressed))
            tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            tap.delegate = self
            return tap
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            menu.view?.removeGestureRecognizer(menu)
            newWindow?.addGestureRecognizer(menu)
        }

        @objc private func pressed() { action() }

        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            active && window?.rootViewController?.presentedViewController == nil
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            active && window?.rootViewController?.presentedViewController == nil
        }

        /// The navigation's own Menu recognizer waits for this one.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            active && other.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue))
        }
    }
}

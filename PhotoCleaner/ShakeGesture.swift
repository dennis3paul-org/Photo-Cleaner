import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted by UIWindow when iOS detects a shake (motionShake event).
    /// SwiftUI views observe this via `.onReceive` to implement shake-to-undo
    /// the same way native iOS apps do.
    static let photoCleanerShake = Notification.Name("photoCleanerShake")
}

extension UIWindow {
    /// Forward shake gestures into a Notification so SwiftUI views can react.
    /// iOS routes motion events up the responder chain and UIWindow is always
    /// in it — overriding motionEnded here catches every shake regardless of
    /// which view is currently focused. The user's Accessibility setting
    /// "Shake to Undo" must be enabled for this to fire.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .photoCleanerShake, object: nil)
        }
    }
}

extension View {
    /// Run `action` when the device is shaken. Convenience wrapper around
    /// the `photoCleanerShake` notification.
    func onShake(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .photoCleanerShake)) { _ in
            action()
        }
    }
}

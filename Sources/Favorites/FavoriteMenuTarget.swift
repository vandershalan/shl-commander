import AppKit

/// Action target for the pop-up favourites menu.
///
/// `NSMenuItem` needs an `NSObject` target that outlives the menu, and `CommandDispatcher` is
/// a struct created per command, so the target lives on `AppState` instead.
@MainActor
final class FavoriteMenuTarget: NSObject {
    /// Set immediately before the menu is shown; receives the favourite's id.
    var onOpen: ((String) -> Void)?

    @objc func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onOpen?(id)
    }
}

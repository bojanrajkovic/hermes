import AppKit
import SwiftUI

/// The popover the diff table shows over a line: a definition, or a line's
/// comments. One at a time; showing another replaces it.
///
/// It is anchored to the table, not to a cell, because the table reuses cells
/// for other rows as the list scrolls.
@MainActor
final class LinePopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var onClose: (() -> Void)?

    var isShown: Bool { popover?.isShown == true }

    /// Shows `content` next to `rect` of `view`.
    ///
    /// - Parameters:
    ///   - size: The popover's size. `nil` sizes it to the content as the content changes.
    ///   - onClose: Called once the popover closes, however it closes.
    func show(_ content: some View, size: CGSize?, relativeTo rect: CGRect, of view: NSView, onClose: @escaping () -> Void) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let controller = NSHostingController(rootView: content)
        if let size {
            popover.contentSize = size
        } else {
            controller.sizingOptions = .preferredContentSize
        }
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        self.onClose = onClose
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover?.performClose(nil)
        finish()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        let closed = ObjectIdentifier(notification.object as AnyObject)
        MainActor.assumeIsolated {
            // A popover this one replaced can report its close after the new one is up.
            guard let popover, ObjectIdentifier(popover) == closed else { return }
            finish()
        }
    }

    private func finish() {
        let onClose = onClose
        self.onClose = nil
        popover = nil
        onClose?()
    }
}

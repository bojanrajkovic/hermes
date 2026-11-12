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
    /// - Parameter onClose: Called once the popover closes, however it closes.
    func show(_ content: some View, size: CGSize, relativeTo rect: CGRect, of view: NSView, onClose: @escaping () -> Void) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = size
        popover.contentViewController = NSHostingController(rootView: content)
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
        MainActor.assumeIsolated { finish() }
    }

    private func finish() {
        let onClose = onClose
        self.onClose = nil
        popover = nil
        onClose?()
    }
}

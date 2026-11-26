import AppKit
import GhosttyTerminal
import HermesUI
import SwiftUI

/// The terminal of one session, with a bar under it once the process exits.
/// Shows nothing for a session opened in the Claude app.
public struct SessionTerminalView: View {
    private let session: ClaudeSession

    public init(session: ClaudeSession) {
        self.session = session
    }

    public var body: some View {
        if let terminal = session.terminal {
            VStack(spacing: 0) {
                TerminalHost(terminal: terminal.view)
                    .accessibilityLabel("Terminal for \(session.title)")
                if session.state == .exited {
                    Divider()
                    exitedBar
                }
            }
        }
    }

    private var exitedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The process exited.")
            Spacer(minLength: 8)
            Button("Restart") { session.restart() }
        }
        .padding(.horizontal, SessionMetrics.barPaddingHorizontal)
        .padding(.vertical, SessionMetrics.barPaddingVertical)
        .background(.bar)
    }
}

/// Shows a session's terminal view. The view belongs to the session: this
/// host borrows it while on screen and parks it offscreen when it goes away,
/// so the process and scrollback outlive the SwiftUI view.
struct TerminalHost: NSViewRepresentable {
    let terminal: TerminalView

    func makeNSView(context _: Context) -> Container {
        let container = Container()
        container.show(terminal)
        return container
    }

    func updateNSView(_ container: Container, context _: Context) {
        container.show(terminal)
    }

    static func dismantleNSView(_ container: Container, coordinator _: ()) {
        container.parkTerminals()
    }

    final class Container: NSView {
        func show(_ terminal: TerminalView) {
            guard terminal.superview !== self else { return }
            parkTerminals()
            terminal.frame = bounds
            terminal.autoresizingMask = [.width, .height]
            addSubview(terminal)
            terminal.setSurfaceVisible(true)
            // Hop the run loop: this runs inside a SwiftUI update, where the
            // first responder must not change.
            DispatchQueue.main.async { [weak terminal] in
                guard let terminal, let window = terminal.window else { return }
                window.makeFirstResponder(terminal)
            }
        }

        /// Parks terminals this container still shows. One that already
        /// moved to another container, or was torn down, is left alone.
        func parkTerminals() {
            for case let terminal as TerminalView in subviews {
                if terminal.controller == nil { terminal.removeFromSuperview() } else { TerminalParking.park(terminal) }
            }
        }
    }
}

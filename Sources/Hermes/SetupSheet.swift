import GitHubKit
import HermesUI
import SessionsUI
import SwiftUI

/// First-run setup, shown once over the first window after sign-in: who
/// Hermes signed in as, where the user's checkouts live, and whether to get
/// changes through webhooks. The last two stay editable in Settings.
struct SetupSheet: View {
    enum Page: Int, CaseIterable { case account, checkouts, updates }

    let viewer: ViewerProfile
    let finish: () -> Void
    @State var page = Page.account

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .account: account
            case .checkouts: checkouts
            case .updates: updates
            }
            Divider()
            HStack {
                Text("Step \(page.rawValue + 1) of \(Page.allCases.count)")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                Spacer()
                if let previous = Page(rawValue: page.rawValue - 1) {
                    Button("Back") { page = previous }
                }
                if let next = Page(rawValue: page.rawValue + 1) {
                    Button("Continue") { page = next }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: finish)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Theme.cardPadding)
        }
        .frame(width: Theme.setupWidth, height: Theme.setupHeight)
    }

    private var account: some View {
        VStack(spacing: 16) {
            AvatarView(url: viewer.avatarURL, size: 72)
            VStack(spacing: 4) {
                Text("Welcome to Hermes")
                    .font(Theme.Fonts.pageTitle)
                Text(verbatim: "Signed in through the GitHub CLI as \(viewer.name ?? viewer.login) (@\(viewer.login)).")
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.readingHorizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        let organizations = viewer.organizations.count
        let accounts = organizations == 0 ? "your account" : organizations == 1
            ? "your account and 1 organization" : "your account and \(organizations) organizations"
        return "Hermes shows the pull requests and issues of \(accounts). Pick one from the Account menu, "
            + "or open a window for each. In a large organization, your own pull requests load first."
    }

    private var checkouts: some View {
        Form {
            Section {
                Text("Where do your clones live? Hermes looks one or two folders deep for them, to start Claude sessions in a worktree of your own checkout.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            CheckoutFoldersSection()
        }
        .formStyle(.grouped)
    }

    private var updates: some View {
        Form {
            Section {
                Text("Hermes refreshes its lists every 15 seconds. For your own repositories it can also hear about a change from GitHub within a couple of seconds.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            WebhooksSection()
        }
        .formStyle(.grouped)
    }
}

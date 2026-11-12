import GitHubKit
import HermesUI
import SessionsUI
import SwiftUI

/// First-run setup, shown once over the first window after sign-in: who
/// Hermes signed in as, then where the user's checkouts live. Both stay
/// editable in Settings.
struct SetupSheet: View {
    enum Page { case account, checkouts }

    let viewer: ViewerProfile
    let finish: () -> Void
    @State var page = Page.account

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .account: account
            case .checkouts: checkouts
            }
            Divider()
            HStack {
                Text(page == .account ? "Step 1 of 2" : "Step 2 of 2")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                Spacer()
                if page == .checkouts {
                    Button("Back") { page = .account }
                    Button("Done", action: finish)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { page = .checkouts }
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
}

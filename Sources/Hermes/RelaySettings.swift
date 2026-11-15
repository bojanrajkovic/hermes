import AppKit
import GitHubKit
import HermesUI
import SwiftUI

/// The relay tenants this Mac uses, and the way to set up another. In Settings and in first-run setup.
struct RelaySection: View {
    @Environment(AppStore.self) private var store
    @State private var isSettingUp = false

    var body: some View {
        Section {
            ForEach(store.relays.memberships) { membership in
                RelayRow(membership: membership)
            }
            Button("Set Up a Relay…") { isSettingUp = true }
                .sheet(isPresented: $isSettingUp) {
                    RelaySetupSheet().environment(store)
                }
        } header: {
            Text("Relay")
        } footer: {
            Text("A relay sends an account's changes to its members as they happen, with no webhook of their own. Setting one up creates a GitHub App that the account owns.")
                .foregroundStyle(.secondary)
        }
    }
}

/// One tenant: whose it is, where its relay runs, and what its owner does next.
private struct RelayRow: View {
    @Environment(AppStore.self) private var store
    let membership: RelayMembership

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let app = membership.app {
                    Link("Install…", destination: RelayAppManifest.installURL(slug: app.slug))
                        .help("Install \(app.slug) on \(app.account), on GitHub")
                    CopyJoinLinkButton(tenant: membership.tenant)
                }
                Button(role: .destructive) {
                    store.relays.forget(membership)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop using this relay on this Mac")
                .accessibilityLabel("Stop using the relay for \(membership.app?.account ?? membership.tenant.server.host() ?? "")")
            }
        } label: {
            Text(verbatim: membership.app?.account ?? "Joined by link")
            Text(verbatim: membership.tenant.server.host() ?? membership.tenant.server.absoluteString)
        }
    }
}

/// Copies a tenant's `hermes://relay.join` link, which its owner sends to the members.
private struct CopyJoinLinkButton: View {
    let tenant: RelayTenant

    var body: some View {
        Button("Copy Join Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tenant.joinLink.absoluteString, forType: .string)
        }
        .help("Members open this link in Hermes to get the account's changes")
    }
}

/// Sets up a tenant: the owner picks an account, the relay, and an invite code, creates the
/// App on GitHub, and comes back to the two steps that are left.
struct RelaySetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var account: Account?
    @State private var server = RelayTenant.defaultServer.absoluteString
    @State private var invite = ""

    /// The accounts the viewer can register an App for: their own and the organizations they own.
    private var accounts: [Account] {
        (store.viewer?.accounts ?? []).filter { $0.kind == .personal || $0.canAdminister }
    }

    private var serverURL: URL? {
        URL(string: server.trimmingCharacters(in: .whitespaces)).flatMap { RelayTenant(server: $0) }?.server
    }

    var body: some View {
        let setup = store.relays.setup
        VStack(spacing: 0) {
            Form {
                switch setup?.phase {
                case nil: start
                case .creatingApp: waiting("Finish creating the App in your browser. GitHub brings you back to Hermes.")
                case .registering: waiting("Registering with the relay…")
                case .failed(let message): failed(message, canRetry: setup?.credentials != nil)
                case .done(let membership): done(membership)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                buttons(setup)
            }
            .padding(Theme.cardPadding)
        }
        .frame(width: Theme.setupWidth, height: Theme.setupHeight)
        .onAppear { account = account ?? accounts.first }
    }

    @ViewBuilder private var start: some View {
        Section {
            Picker("Account", selection: $account) {
                ForEach(accounts) { account in
                    Text(verbatim: account.login).tag(Account?.some(account))
                }
            }
            TextField("Relay server", text: $server)
            TextField("Invite code", text: $invite, prompt: Text("From the relay's operator"))
        } footer: {
            Text("Hermes opens GitHub to create an App that \(account?.login ?? "the account") owns. The App reads pull requests, issues, checks, commit statuses, and members, and sends their events to the relay. The relay passes each event on to the members who can see its repository and keeps none.")
                .foregroundStyle(.secondary)
        }
    }

    private func waiting(_ text: String) -> some View {
        Section {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
            }
        }
    }

    @ViewBuilder private func failed(_ message: String, canRetry: Bool) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if canRetry {
                TextField("Invite code", text: $invite)
            }
        } footer: {
            if canRetry {
                Text("GitHub made the App. Registering can be tried again with another invite code.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func done(_ membership: RelayMembership) -> some View {
        if let app = membership.app {
            Section {
                LabeledContent {
                    Link("Install…", destination: RelayAppManifest.installURL(slug: app.slug))
                } label: {
                    Text(verbatim: "1. Install \(app.slug) on \(app.account)")
                    Text("GitHub sends events only for the repositories the App is installed on.")
                }
                LabeledContent {
                    CopyJoinLinkButton(tenant: membership.tenant)
                } label: {
                    Text("2. Send the join link to the members")
                    Text("Each member opens it in Hermes. Both steps stay in Settings.")
                }
            } header: {
                Text(verbatim: "The relay is set up for \(app.account)")
            }
        }
    }

    @ViewBuilder private func buttons(_ setup: Relays.Setup?) -> some View {
        switch setup?.phase {
        case .done:
            Button("Done") { close() }
                .keyboardShortcut(.defaultAction)
        case .failed where setup?.credentials != nil:
            Button("Cancel", role: .cancel) { close() }
            Button("Try Again") { Task { await store.relays.register(invite: invite.trimmingCharacters(in: .whitespaces)) } }
                .keyboardShortcut(.defaultAction)
                .disabled(invite.trimmingCharacters(in: .whitespaces).isEmpty)
        case .failed:
            Button("Close") { close() }
                .keyboardShortcut(.defaultAction)
        case .creatingApp, .registering:
            Button("Cancel", role: .cancel) { close() }
        case nil:
            Button("Cancel", role: .cancel) { close() }
            Button("Create App on GitHub") {
                guard let account, let serverURL else { return }
                store.relays.beginSetup(account: account, server: serverURL, invite: invite.trimmingCharacters(in: .whitespaces))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(account == nil || serverURL == nil || invite.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func close() {
        store.relays.endSetup()
        dismiss()
    }
}

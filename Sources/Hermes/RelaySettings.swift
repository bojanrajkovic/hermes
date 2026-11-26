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
            ForEach(store.relays.available) { published in
                PublishedRelayRow(published: published)
            }
            Button("Set Up a Relay…") { isSettingUp = true }
                .sheet(isPresented: $isSettingUp) {
                    RelaySetupSheet().environment(store)
                }
        } header: {
            Text("Relay")
        } footer: {
            Text("A relay sends an account's changes to its members as they happen, with no webhook of their own. Setting one up creates a GitHub App that the account owns. To join one, open the link its owner sent you, or connect to one an account of yours publishes.")
                .foregroundStyle(.secondary)
        }
        .task { await store.relays.loadVersions() }
    }
}

/// One tenant: whose it is, what its connection is doing, where its relay runs, and what
/// the user does next.
private struct RelayRow: View {
    @Environment(AppStore.self) private var store
    let membership: RelayMembership

    private var state: RelayState? { store.relays.states[membership.id] }

    /// The account that set the tenant up or publishes it. For a tenant with neither, the
    /// owners of the repositories the relay says it covers.
    private var title: String {
        if let app = membership.app { return app.account }
        if let published = store.relays.published.first(where: { $0.tenant == membership.tenant }) { return published.account }
        guard case .connected(let repositories) = state, !repositories.isEmpty else { return "Joined by link" }
        return Set(repositories.map(\.owner)).sorted().joined(separator: ", ")
    }

    private var status: String {
        switch state {
        case nil: "Not connected"
        case .signedOut: "Not signed in"
        case .connecting: "Connecting…"
        case .connected(let repositories): repositories.count == 1 ? "Connected, 1 repository" : "Connected, \(repositories.count) repositories"
        case .waiting(_, let error): error.isEmpty ? "Reconnecting" : "Reconnecting: \(error)"
        case .gone: "The relay no longer has this tenant"
        }
    }

    /// When the tenant last sent an event. "Connected" proves only that the relay answered;
    /// this proves events arrive. Nothing until the tenant has connected once.
    @ViewBuilder
    private var lastEvent: some View {
        if let date = store.relays.lastEvents[membership.id] {
            // Each tick formats the age against the clock again, so it moves while Settings stays open.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Last event \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
                    .help(date.formatted(date: .abbreviated, time: .standard))
            }
        } else if case .connected = state {
            Text("No events since connecting")
        }
    }

    /// The server's host, and the commit its relay runs once the server has answered.
    private var server: String {
        let host = membership.tenant.server.host() ?? membership.tenant.server.absoluteString
        guard let commit = store.relays.versions[membership.tenant.server] else { return host }
        return "\(host), commit \(commit.prefix(7))"
    }

    private var publishAccounts: [String] {
        let repositories: Set<RepositoryRef> = if case .connected(let repositories) = state { repositories } else { [] }
        let owned = (store.viewer?.accounts ?? []).filter { $0.kind == .personal || $0.canAdminister }
        return membership.publishAccounts(repositories: repositories, ownedAccounts: owned.map(\.login))
    }

    private func publish(in account: String) {
        Task { await publishRelay(membership.tenant, for: account, client: store.client) }
    }

    var body: some View {
        let publishAccounts = publishAccounts
        LabeledContent {
            HStack(spacing: 8) {
                if state == .signedOut {
                    Button("Sign In") { store.relays.signIn(membership) }
                        .help("Sign in with GitHub in your browser, through the account's App")
                }
                if let app = membership.app {
                    Link("Install…", destination: RelayAppManifest.installURL(slug: app.slug))
                        .help("Install \(app.slug) on \(app.account), on GitHub")
                }
                if publishAccounts.count == 1, let account = publishAccounts.first {
                    Button("Publish…") { publish(in: account) }
                        .help("Commit the tenant's file to \(account)/.github-private, so the account's members can find the tenant without a link")
                } else if !publishAccounts.isEmpty {
                    Menu("Publish") {
                        ForEach(publishAccounts, id: \.self) { account in
                            Button("In \(account)/.github-private…") { publish(in: account) }
                        }
                    }
                    .fixedSize()
                    .help("Commit the tenant's file to an account's .github-private repository, so its members can find the tenant without a link")
                }
                CopyJoinLinkButton(tenant: membership.tenant)
                Button(role: .destructive) {
                    store.relays.forget(membership)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop using this relay on this Mac")
                .accessibilityLabel("Stop using the relay for \(title)")
            }
        } label: {
            Text(verbatim: title)
            Text(verbatim: status)
            lastEvent
            Text(verbatim: server)
        }
        .contextMenu {
            ForEach(publishAccounts, id: \.self) { account in
                Button("Publish in \(account)/.github-private…") { publish(in: account) }
            }
            Button("Copy Join Link") { copyJoinLink(membership.tenant) }
            Button("Stop Using This Relay", role: .destructive) { store.relays.forget(membership) }
        }
    }
}

/// A tenant one of the viewer's accounts publishes and this Mac does not use: where its
/// relay runs, and the way to connect. The launch asks about each once, and this row is
/// how to say yes later.
private struct PublishedRelayRow: View {
    @Environment(AppStore.self) private var store
    let published: PublishedRelay

    var body: some View {
        let refusal = store.relays.refusal(of: published.tenant)
        LabeledContent {
            if refusal == nil {
                Button("Connect") { store.relays.join(published.tenant, organization: published.organization) }
                    .help("Sign in with GitHub in your browser, through the account's App")
            }
        } label: {
            Text(verbatim: published.account)
            Text(verbatim: refusal ?? "Publishes a relay this Mac does not use")
            Text(verbatim: published.tenant.server.host() ?? published.tenant.server.absoluteString)
        }
    }
}

private func copyJoinLink(_ tenant: RelayTenant) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(tenant.joinLink.absoluteString, forType: .string)
}

/// Asks the owner, then commits the tenant's file to the account's `.github-private` repository, where
/// a member's Hermes finds it, and says how that went.
@MainActor
private func publishRelay(_ tenant: RelayTenant, for account: String, client: GitHubClient) async {
    let question = NSAlert()
    question.messageText = "Publish the relay in \(account)/.github-private?"
    question.informativeText = "Hermes commits \(RelayDiscovery.fileName) there, with the relay's address and the tenant's ID. A member's Hermes finds it and offers to connect, so nobody needs the join link. Anyone who can see \(account)/.github-private can see the file."
    question.addButton(withTitle: "Commit")
    question.addButton(withTitle: "Cancel")
    guard question.runModal() == .alertFirstButtonReturn else { return }

    let answer = NSAlert()
    do {
        switch try await client.publishRelay(tenant, for: account) {
        case .published:
            answer.messageText = "Published in \(account)/.github-private"
            answer.informativeText = "Hermes offers the relay to each member the next time they open it."
        case .noRepository:
            answer.messageText = "\(account) has no .github-private repository"
            answer.informativeText = "Create a private repository with that name on GitHub to publish the relay there. Until then, send the members the join link."
        }
    } catch {
        answer.alertStyle = .warning
        answer.messageText = "Could Not Publish the Relay"
        answer.informativeText = "\(describe(error)) The join link still works."
    }
    answer.runModal()
}

/// Copies a tenant's `hermes://relay.join` link, which its owner sends to the members.
private struct CopyJoinLinkButton: View {
    let tenant: RelayTenant

    var body: some View {
        Button("Copy Join Link") { copyJoinLink(tenant) }
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
    /// Hermes is asking the relay whether it is there, before it sends the owner to GitHub.
    @State private var isContacting = false
    /// Why the setup did not start, such as a relay that did not answer.
    @State private var startError: String?

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
                case .failed(let message): failed(message, setup: setup)
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
            if let startError {
                Label(startError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
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

    @ViewBuilder private func failed(_ message: String, setup: Relays.Setup?) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if setup?.credentials != nil {
                TextField("Invite code", text: $invite)
            }
        } footer: {
            if setup?.credentials != nil {
                Text("GitHub made the App. Registering can be tried again with another invite code.")
                    .foregroundStyle(.secondary)
            } else if setup?.code != nil {
                Text("GitHub made the App and keeps its secrets for an hour. Hermes can ask for them again.")
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
                    Text("Each member opens it in Hermes and signs in. You sign in from Settings, once the App is installed.")
                }
                LabeledContent {
                    Button("Publish…") {
                        Task { await publishRelay(membership.tenant, for: app.account, client: store.client) }
                    }
                } label: {
                    Text(verbatim: "Or publish the relay in \(app.account)/.github-private")
                    Text("Hermes then offers it to each member, and nobody needs the link.")
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
        case .failed where setup?.canRetry == true:
            Button("Cancel", role: .cancel) { close() }
            Button("Try Again") { Task { await store.relays.retrySetup(invite: invite.trimmingCharacters(in: .whitespaces)) } }
                .keyboardShortcut(.defaultAction)
                // Only registering takes the invite code. Asking GitHub again takes nothing.
                .disabled(setup?.credentials != nil && invite.trimmingCharacters(in: .whitespaces).isEmpty)
        case .failed:
            Button("Close") { close() }
                .keyboardShortcut(.defaultAction)
        case .creatingApp, .registering:
            Button("Cancel", role: .cancel) { close() }
        case nil:
            Button("Cancel", role: .cancel) { close() }
            Button("Create App on GitHub") {
                guard let account, let serverURL else { return }
                isContacting = true
                Task {
                    startError = await store.relays.beginSetup(account: account, server: serverURL, invite: invite.trimmingCharacters(in: .whitespaces))
                    isContacting = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(account == nil || serverURL == nil || isContacting || invite.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func close() {
        store.relays.endSetup()
        dismiss()
    }
}

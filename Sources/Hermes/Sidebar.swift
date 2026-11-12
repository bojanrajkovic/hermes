import AppKit
import GitHubKit
import HermesUI
import SwiftUI

// MARK: Account picker and profile

/// The dropdown at the top of the sidebar that switches between the personal
/// account and the viewer's organizations.
struct AccountPicker: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.viewer?.accounts ?? []) { account in
                Toggle(isOn: Binding(get: { account == model.account }, set: { _ in model.select(account) })) {
                    Label {
                        Text(account.name ?? account.login)
                    } icon: {
                        if let image = AvatarCache.shared.menuImage(for: account.avatarURL) {
                            Image(nsImage: image)
                        } else {
                            Image(systemName: account.kind == .personal ? "person.crop.circle" : "building.2.crop.circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.rowGlyphSpacing) {
                AvatarView(url: model.account?.avatarURL, size: 20)
                Text(model.account.map { $0.name ?? $0.login } ?? "No account")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel("Account: \(model.account?.login ?? "none")")
        .help("Switch account")
    }
}

/// The control at the bottom of the sidebar that shows who is logged in and
/// opens their profile.
struct ProfileButton: View {
    let viewer: ViewerProfile
    @State private var isShowingProfile = false

    var body: some View {
        Button {
            isShowingProfile.toggle()
        } label: {
            HStack(spacing: Theme.rowGlyphSpacing) {
                AvatarView(url: viewer.avatarURL, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(viewer.name ?? viewer.login)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "@\(viewer.login)")
                        .font(Theme.Fonts.rowMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Signed in as \(viewer.login)")
        .accessibilityLabel("Signed in as \(viewer.name ?? viewer.login). Show profile.")
        .popover(isPresented: $isShowingProfile, arrowEdge: .trailing) {
            ProfileCard(viewer: viewer)
        }
    }
}

struct ProfileCard: View {
    let viewer: ViewerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(url: viewer.avatarURL, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewer.name ?? viewer.login)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: "@\(viewer.login)")
                        .foregroundStyle(.secondary)
                }
            }
            if let bio = viewer.bio, !bio.isEmpty {
                Text(bio).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let company = viewer.company, !company.isEmpty { Label(company, systemImage: "building.2") }
                if let location = viewer.location, !location.isEmpty { Label(location, systemImage: "mappin.and.ellipse") }
                if let email = viewer.email, !email.isEmpty { Label(email, systemImage: "envelope").textSelection(.enabled) }
                if !viewer.organizations.isEmpty {
                    Label(
                        viewer.organizations.count == 1 ? "1 organization" : "\(viewer.organizations.count) organizations",
                        systemImage: "person.3"
                    )
                }
            }
            .foregroundStyle(.secondary)
            Divider()
            Link(destination: viewer.profileURL) {
                Label("Open GitHub Profile", systemImage: "arrow.up.right.square")
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: Sidebar frame

/// The parts every sidebar shares: the account picker above the list, the
/// profile below it, and the loading and error states of the lists.
struct SidebarFrame<Content: View>: View {
    @Environment(WindowModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if model.hasLoaded {
                content
            } else if let error = model.listError {
                ContentUnavailableView {
                    Label("Could Not Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading pull requests…").foregroundStyle(.secondary)
                }
            }
        }
        // Every state fills the column, so the bars below stay at its edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                AccountPicker()
                Divider()
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.hasLoaded, let error = model.listError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.rowMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("The lists could not refresh. Press ⌘R to try again.")
                }
                Divider()
                if let viewer = model.viewer { ProfileButton(viewer: viewer) }
            }
            // The list scrolls under this bar, so it needs its own backing.
            .background(.bar)
        }
    }
}

// MARK: Sidebar

/// The sidebar: the cross-repository filters, then the repositories with their counts.
struct ScopeSidebar: View {
    @Environment(WindowModel.self) private var model
    /// The list's own selection, which follows the model's scope a moment
    /// late. A sidebar list that has a selected row in its first frame keeps
    /// that row's title bold after the selection moves to another row.
    @State private var selection: Scope?

    var body: some View {
        SidebarFrame {
            List(selection: $selection) {
                Section("Pull Requests") {
                    ForEach(InboxFilter.allCases) { filter in
                        Label(filter.title, systemImage: filter.symbol)
                            .badge(model.count(for: filter))
                            .tag(Scope.filter(filter))
                    }
                }
                if !model.sessions.sessions.isEmpty {
                    Section("Claude") {
                        Label("Sessions", systemImage: "terminal")
                            .badge(model.sessions.sessions.count)
                            .tag(Scope.sessions)
                    }
                }
                Section("Repositories") {
                    ForEach(model.sections) { section in
                        RepositoryRow(section: section).tag(Scope.repository(section.ref))
                    }
                }
            }
            .listStyle(.sidebar)
            .modifier(ScrollsToRequestedRow())
            .task(id: model.scope) {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled { selection = model.scope }
            }
            .onChange(of: selection) {
                if let selection, selection != model.scope { model.show(selection) }
            }
        }
    }
}

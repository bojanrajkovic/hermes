import StateKit
import SwiftUI

extension View {
    /// Keeps `interest` fresh in `store` while this view is on screen. Views that show the
    /// same interest share one poll, and it stops when the last of them goes away.
    public func showing(_ interest: Interest, in store: GitHubStore) -> some View {
        task(id: interest) { await store.showing(interest) }
    }
}

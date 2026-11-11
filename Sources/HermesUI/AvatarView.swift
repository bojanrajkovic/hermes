import AppKit
import SwiftUI

/// Loads avatar images once and keeps them for the life of the app, so a row
/// that scrolls back into view shows its avatar without a second request.
@MainActor
public final class AvatarCache {
    public static let shared = AvatarCache()

    private var images: [URL: NSImage] = [:]
    private var loads: [URL: Task<NSImage?, Never>] = [:]

    /// The image for `url` when it has already been loaded.
    public func cached(_ url: URL) -> NSImage? { images[url] }

    /// Loads the image for `url`. Concurrent calls for one URL share a request.
    public func image(for url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        if let load = loads[url] { return await load.value }

        let load = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        loads[url] = load
        let image = await load.value
        loads[url] = nil
        images[url] = image
        return image
    }

    /// A round copy of the cached image for `url`, for places that take only an
    /// `NSImage`, such as menu items. Nil until the image has been loaded.
    public func menuImage(for url: URL, size: CGFloat = 16) -> NSImage? {
        guard let image = images[url] else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
    }
}

/// A round avatar. Shows a person symbol until the image loads, and when
/// `url` is nil.
public struct AvatarView: View {
    private let url: URL?
    private let size: CGFloat
    @State private var image: NSImage?

    public init(url: URL?, size: CGFloat = Theme.avatarSize) {
        self.url = url
        self.size = size
        _image = State(initialValue: url.flatMap { AvatarCache.shared.cached($0) })
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await AvatarCache.shared.image(for: url)
        }
    }
}

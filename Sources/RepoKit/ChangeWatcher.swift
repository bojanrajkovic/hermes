import CoreServices
import Foundation

extension WorkingTree {
    /// Emits a value when the worktree's files change or when its `HEAD`,
    /// index, or refs move. Bursts are collapsed: one value is emitted 300 ms
    /// after the first change, and later changes start the next 300 ms.
    ///
    /// Changes inside `.build`, `node_modules`, `target`, and `dist` are
    /// ignored, as is everything in the git directory except `HEAD`, `index`,
    /// `packed-refs`, and `refs/`. Watching stops when the stream's consumer
    /// stops iterating or its task is cancelled.
    public func changes() -> AsyncStream<Void> {
        let layout = WatchLayout(worktree: directory)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = FileWatcher(layout: layout) { continuation.yield() }
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }
}

/// The directories that hold a worktree's state, and which paths in them count as a change.
struct WatchLayout: Sendable {
    /// The worktree's root, with symlinks resolved, as FSEvents reports paths.
    let worktree: String
    /// Holds this worktree's `HEAD` and `index`. Outside `worktree` for a linked worktree.
    let gitDirectory: String
    /// Holds refs shared by all of the checkout's worktrees.
    let commonDirectory: String

    private static let ignoredDirectories: Set<Substring> = [".git", ".build", "node_modules", "target", "dist"]

    init(worktree directory: URL) {
        func resolved(_ path: String) -> String {
            guard let real = realpath(path, nil) else { return path }
            defer { free(real) }
            return String(cString: real)
        }
        func firstLine(of file: String) -> String? {
            (try? String(contentsOfFile: file, encoding: .utf8))?
                .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func absolute(_ path: String, from base: String) -> String {
            resolved(path.hasPrefix("/") ? path : base + "/" + path)
        }

        let worktree = resolved(directory.path)
        // In a linked worktree `.git` is a file: "gitdir: <path>".
        var gitDirectory = worktree + "/.git"
        if let pointer = firstLine(of: gitDirectory), pointer.hasPrefix("gitdir:") {
            gitDirectory = absolute(String(pointer.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces), from: worktree)
        }
        var commonDirectory = gitDirectory
        if let pointer = firstLine(of: gitDirectory + "/commondir") {
            commonDirectory = absolute(pointer, from: gitDirectory)
        }
        (self.worktree, self.gitDirectory, self.commonDirectory) = (worktree, gitDirectory, commonDirectory)
    }

    /// The directories to watch. The git directories are listed only when they are outside the worktree.
    var roots: [String] {
        var roots = [worktree]
        for directory in [gitDirectory, commonDirectory] where !roots.contains(where: { directory.isInside($0) }) {
            roots.append(directory)
        }
        return roots
    }

    /// Whether a change to `path` should reach the consumer.
    func isRelevant(_ path: String) -> Bool {
        func isRef(_ relative: Substring) -> Bool { relative == "packed-refs" || relative.hasPrefix("refs/") }

        if let relative = path.relative(to: gitDirectory) {
            return relative == "HEAD" || relative == "index" || isRef(relative)
        }
        if let relative = path.relative(to: commonDirectory) {
            return isRef(relative)
        }
        guard let relative = path.relative(to: worktree) else { return false }
        return !relative.split(separator: "/").contains(where: Self.ignoredDirectories.contains)
    }
}

private extension String {
    /// The part of the path below `directory`, or `nil` if it is not inside it.
    func relative(to directory: String) -> Substring? {
        hasPrefix(directory + "/") ? dropFirst(directory.count + 1) : nil
    }

    func isInside(_ directory: String) -> Bool {
        self == directory || relative(to: directory) != nil
    }
}

/// An FSEvents stream that reports at most one change per 300 ms. All state is confined to `queue`.
private final class FileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hermes.repokit.file-watcher")
    private let layout: WatchLayout
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(layout: WatchLayout, onChange: @escaping @Sendable () -> Void) {
        self.layout = layout
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            // The stream retains `self` until stop() releases it, so a callback
            // that was already queued never sees a freed watcher.
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in info.map { _ = Unmanaged<FileWatcher>.fromOpaque($0).retain() }; return info },
                release: { info in info.map { Unmanaged<FileWatcher>.fromOpaque($0).release() } },
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().handle(paths)
            }
            let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, layout.roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(flags)
            ) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
        }
    }

    func stop() {
        queue.async { [self] in
            pending?.cancel()
            pending = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Called on `queue`.
    private func handle(_ paths: [String]) {
        // Timing from the first change keeps continuous writes from postponing the value forever.
        guard pending == nil, paths.contains(where: layout.isRelevant) else { return }
        let item = DispatchWorkItem { [self] in
            pending = nil
            onChange()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: item)
    }
}

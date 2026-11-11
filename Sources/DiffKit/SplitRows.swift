/// One row of a side-by-side layout: the old file on the left, the new file on the right.
public enum SplitRow: Sendable, Hashable {
    /// An unchanged line, shown on both sides.
    case context(DiffLine)
    /// A deletion and the addition that replaced it.
    case paired(deletion: DiffLine, addition: DiffLine)
    /// A deletion with nothing on the right.
    case deletion(DiffLine)
    /// An addition with nothing on the left.
    case addition(DiffLine)

    /// The line for the left side, or `nil` when the row is an unpaired addition.
    public var old: DiffLine? {
        switch self {
        case .context(let line), .deletion(let line), .paired(let line, _): line
        case .addition: nil
        }
    }

    /// The line for the right side, or `nil` when the row is an unpaired deletion.
    public var new: DiffLine? {
        switch self {
        case .context(let line), .addition(let line), .paired(_, let line): line
        case .deletion: nil
        }
    }
}

extension Hunk {
    /// The hunk's lines arranged for a side-by-side layout.
    ///
    /// A change block is a run of deletions and additions with no context line
    /// between them. Within a block, the first deletion pairs with the first
    /// addition, the second with the second, and so on. The longer side's
    /// extra lines get rows of their own.
    public var splitRows: [SplitRow] {
        var rows: [SplitRow] = []
        rows.reserveCapacity(lines.count)
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []

        func flush() {
            let paired = min(deletions.count, additions.count)
            for index in 0..<paired {
                rows.append(.paired(deletion: deletions[index], addition: additions[index]))
            }
            rows += deletions[paired...].map(SplitRow.deletion)
            rows += additions[paired...].map(SplitRow.addition)
            deletions.removeAll(keepingCapacity: true)
            additions.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.kind {
            case .deletion: deletions.append(line)
            case .addition: additions.append(line)
            case .context:
                flush()
                rows.append(.context(line))
            }
        }
        flush()
        return rows
    }
}

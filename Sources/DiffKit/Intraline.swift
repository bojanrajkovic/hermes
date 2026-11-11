/// The parts of a deleted line and its replacement that differ.
public struct IntralineChange: Sendable, Hashable {
    /// Changed ranges in the old line's text, in order. Indices belong to the
    /// `old` string passed to `intralineChange(old:new:)`.
    public let old: [Range<String.Index>]
    /// Changed ranges in the new line's text, in order.
    public let new: [Range<String.Index>]
}

/// Finds the changed character ranges between a deleted line and the added line paired with it.
///
/// The lines are split into tokens (words, runs of whitespace, single
/// punctuation characters) and diffed. Each changed stretch is then narrowed
/// by the characters its two sides share at the start and end, so `fooBar` to
/// `fooBaz` marks only `r` and `z`. Range bounds fall on Unicode scalar
/// boundaries.
///
/// - Returns: `nil` when highlighting would not help: less than 40% of the
///   lines' non-whitespace text is unchanged, or either line is longer than
///   2,000 UTF-8 bytes or 400 tokens. Equal lines give empty ranges.
public func intralineChange(old: String, new: String) -> IntralineChange? {
    let a = Array(old.utf8), b = Array(new.utf8)
    // shortcut: long (minified) lines get no highlight, because the token diff
    // is quadratic in the worst case. Raise the cap if such lines matter.
    guard a.count <= 2000, b.count <= 2000 else { return nil }

    let oldTokens = tokens(a), newTokens = tokens(b)
    // shortcut: the same skip for lines of many short tokens (CSV numbers,
    // punctuation runs), where two unlike 2,000-byte lines cost about 250 ms.
    guard oldTokens.count <= 400, newTokens.count <= 400 else { return nil }
    let difference = newTokens.map { b[$0] }.difference(from: oldTokens.map { a[$0] })
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in difference {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }

    var oldRanges: [Range<Int>] = [], newRanges: [Range<Int>] = []
    var i = 0, j = 0
    while i < oldTokens.count || j < newTokens.count {
        let firstOld = i, firstNew = j
        while i < oldTokens.count, removed.contains(i) { i += 1 }
        while j < newTokens.count, inserted.contains(j) { j += 1 }
        if i == firstOld, j == firstNew {
            // An unchanged token on both sides.
            i += 1
            j += 1
            continue
        }
        var oldGap = firstOld < i ? oldTokens[firstOld].lowerBound..<oldTokens[i - 1].upperBound : 0..<0
        var newGap = firstNew < j ? newTokens[firstNew].lowerBound..<newTokens[j - 1].upperBound : 0..<0
        trimCommonEnds(&oldGap, in: a, &newGap, in: b)
        if !oldGap.isEmpty { oldRanges.append(oldGap) }
        if !newGap.isEmpty { newRanges.append(newGap) }
    }

    // Whitespace is left out so that shared indentation does not make unrelated lines look alike.
    func weight(_ bytes: [UInt8], _ ranges: [Range<Int>]) -> Int {
        ranges.reduce(0) { $0 + bytes[$1].count { !isSpace($0) } }
    }
    let total = weight(a, [0..<a.count]) + weight(b, [0..<b.count])
    let changed = weight(a, oldRanges) + weight(b, newRanges)
    guard total == 0 || Double(total - changed) / Double(total) >= 0.4 else { return nil }

    func indices(_ ranges: [Range<Int>], in string: String) -> [Range<String.Index>] {
        let utf8 = string.utf8
        return ranges.map {
            utf8.index(utf8.startIndex, offsetBy: $0.lowerBound)..<utf8.index(utf8.startIndex, offsetBy: $0.upperBound)
        }
    }
    return IntralineChange(old: indices(oldRanges, in: old), new: indices(newRanges, in: new))
}

private func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09
}

/// Letters, digits, `_`, and every non-ASCII byte. Keeping non-ASCII bytes in
/// words means a token never splits a UTF-8 sequence.
private func isWord(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x80...: true
    default: false
    }
}

private func tokens(_ bytes: [UInt8]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var start = 0
    while start < bytes.count {
        var end = start + 1
        if isWord(bytes[start]) {
            while end < bytes.count, isWord(bytes[end]) { end += 1 }
        } else if isSpace(bytes[start]) {
            while end < bytes.count, isSpace(bytes[end]) { end += 1 }
        }
        result.append(start..<end)
        start = end
    }
    return result
}

/// Shrinks two changed ranges by the bytes they share at the start and at the
/// end, without cutting inside a UTF-8 sequence.
private func trimCommonEnds(_ x: inout Range<Int>, in a: [UInt8], _ y: inout Range<Int>, in b: [UInt8]) {
    func isContinuation(_ bytes: [UInt8], _ index: Int, _ range: Range<Int>) -> Bool {
        index < range.upperBound && bytes[index] & 0xC0 == 0x80
    }
    let limit = min(x.count, y.count)

    var prefix = 0
    while prefix < limit, a[x.lowerBound + prefix] == b[y.lowerBound + prefix] { prefix += 1 }
    while prefix > 0, isContinuation(a, x.lowerBound + prefix, x) || isContinuation(b, y.lowerBound + prefix, y) {
        prefix -= 1
    }

    var suffix = 0
    while suffix < limit - prefix, a[x.upperBound - suffix - 1] == b[y.upperBound - suffix - 1] { suffix += 1 }
    while suffix > 0, isContinuation(a, x.upperBound - suffix, x) { suffix -= 1 }

    x = (x.lowerBound + prefix)..<(x.upperBound - suffix)
    y = (y.lowerBound + prefix)..<(y.upperBound - suffix)
}

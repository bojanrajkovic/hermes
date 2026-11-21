import Foundation

/// A value with the start time of the fetch that produced it.
///
/// Two fetches can return the same fact in either order. The one that started later saw
/// GitHub later, so its answer wins even when it arrives first.
public struct Stamped<Value: Sendable>: Sendable {
    public private(set) var value: Value
    public private(set) var fetchedAt: Date

    public init(_ value: Value, fetchedAt: Date) {
        self.value = value
        self.fetchedAt = fetchedAt
    }

    /// Takes a fetch's answer unless a fetch that started later already wrote.
    ///
    /// - Returns: Whether `value` was taken.
    @discardableResult
    public mutating func write(_ value: Value, startedAt: Date) -> Bool {
        guard startedAt >= fetchedAt else { return false }
        self.value = value
        fetchedAt = startedAt
        return true
    }
}

extension Stamped: Equatable where Value: Equatable {}

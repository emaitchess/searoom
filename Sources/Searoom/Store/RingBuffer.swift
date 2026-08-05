struct RingBuffer<Element: Sendable>: RandomAccessCollection, Sendable {
    typealias Index = Int

    private var storage: [Element?] = []
    private var head = 0
    private(set) var count = 0

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> Element {
        precondition(indices.contains(position), "Ring buffer index out of bounds")
        return storage[physicalIndex(for: position)]!
    }

    mutating func append(_ element: Element, maximumCount: Int) {
        guard maximumCount > 0 else {
            removeAll(keepingCapacity: false)
            return
        }
        trim(to: maximumCount)
        ensureCapacity(for: count + 1, maximumCount: maximumCount)

        if count < storage.count {
            storage[physicalIndex(for: count)] = element
            count += 1
        } else {
            storage[head] = element
            head = (head + 1) % storage.count
        }
    }

    mutating func replaceContents<S: Sequence>(
        _ elements: S,
        maximumCount: Int
    ) where S.Element == Element {
        removeAll(keepingCapacity: false)
        for element in elements {
            append(element, maximumCount: maximumCount)
        }
    }

    mutating func removeFirst(
        while shouldRemove: (Element) -> Bool,
        keepingAtLeast minimumCount: Int = 0
    ) {
        while count > minimumCount, let first = storage[head], shouldRemove(first) {
            storage[head] = nil
            head = (head + 1) % storage.count
            count -= 1
        }
        if count == 0 { head = 0 }
    }

    mutating func trim(to maximumCount: Int) {
        let maximumCount = Swift.max(0, maximumCount)
        while count > maximumCount {
            storage[head] = nil
            head = (head + 1) % storage.count
            count -= 1
        }
        guard storage.count > maximumCount else { return }
        rebuild(capacity: maximumCount)
    }

    mutating func removeAll(keepingCapacity: Bool) {
        if keepingCapacity {
            for index in storage.indices { storage[index] = nil }
        } else {
            storage.removeAll(keepingCapacity: false)
        }
        head = 0
        count = 0
    }

    func snapshot() -> [Element] { Array(self) }

    private func physicalIndex(for logicalIndex: Int) -> Int {
        (head + logicalIndex) % storage.count
    }

    private mutating func ensureCapacity(for requiredCount: Int, maximumCount: Int) {
        guard requiredCount > storage.count, storage.count < maximumCount else { return }
        let doubled = Swift.max(16, storage.count * 2)
        rebuild(capacity: Swift.min(maximumCount, Swift.max(requiredCount, doubled)))
    }

    private mutating func rebuild(capacity: Int) {
        guard capacity > 0 else {
            storage = []
            head = 0
            count = 0
            return
        }
        let retainedCount = Swift.min(count, capacity)
        let firstRetainedIndex = count - retainedCount
        var replacement = [Element?](repeating: nil, count: capacity)
        for index in 0..<retainedCount {
            replacement[index] = self[firstRetainedIndex + index]
        }
        storage = replacement
        head = 0
        count = retainedCount
    }
}

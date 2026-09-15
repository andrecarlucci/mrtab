import Foundation

/// Numbers 1-9 pinned to windows by hand, so a window can be reached by typing its digit.
/// Marks live as long as MrTab does; a window that goes away takes its number with it.
final class WindowMarks {
    static let range = 1...9

    private var numbers: [AXRef: Int] = [:]

    func mark(for ref: AXRef) -> Int? { numbers[ref] }

    func ref(for mark: Int) -> AXRef? {
        numbers.first { $0.value == mark }?.key
    }

    /// Clears the window's number if it has one, otherwise hands it the lowest one going spare.
    /// Does nothing once all nine are taken.
    func toggle(_ ref: AXRef) {
        guard numbers.removeValue(forKey: ref) == nil else { return }
        let taken = Set(numbers.values)
        guard let free = Self.range.first(where: { !taken.contains($0) }) else { return }
        numbers[ref] = free
    }

    func forget(_ ref: AXRef) {
        numbers.removeValue(forKey: ref)
    }

    /// Drops marks whose window is gone, so its number goes back into circulation.
    func prune(keeping live: Set<AXRef>) {
        numbers = numbers.filter { live.contains($0.key) }
    }
}

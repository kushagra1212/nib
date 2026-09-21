import Foundation

extension Array {
    /// Indexing that returns nil rather than trapping.
    ///
    /// Used where an index comes from a button's tag: a stale view can outlive
    /// the list it was built from, and a crash is a poor way to report that.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

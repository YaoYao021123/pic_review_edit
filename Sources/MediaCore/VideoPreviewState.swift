import Foundation

/// Filter callbacks run outside the main actor. Publish one complete parameter
/// snapshot so the player can keep its decoder and composition while editing.
public final class VideoPreviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MediaEdits
    private var original = false
    public let maximumDimension: Double

    public init(edits: MediaEdits, maximumDimension: Double = 1920) {
        value = edits
        self.maximumDimension = maximumDimension.isFinite ? max(2, maximumDimension) : 1920
    }
    public func update(_ edits: MediaEdits) {
        lock.lock(); defer { lock.unlock() }
        value = edits
    }
    public func snapshot() -> MediaEdits {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    /// Show the ungraded source in the same composition (before/after compare)
    /// instead of rebuilding the player item.
    public var showsOriginal: Bool {
        get { lock.lock(); defer { lock.unlock() }; return original }
        set { lock.lock(); original = newValue; lock.unlock() }
    }
}

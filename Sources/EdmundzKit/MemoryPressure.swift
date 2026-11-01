import Foundation

/// Drops every cache (decoded images, rendered math, diagrams) and the web view when the system is short on memory.
public final class MemoryPressure {
    public static let shared = MemoryPressure()
    private var source: DispatchSourceMemoryPressure?
    public var onPurge: [() -> Void] = []

    public func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { [weak self] in self?.purge() }
        s.resume()
        source = s
    }

    public func purge() {
        ImageStore.shared.purge()
        MathRenderer.purge()
        Task { @MainActor in WebRenderer.shared.purge() }
        onPurge.forEach { $0() }
    }
}

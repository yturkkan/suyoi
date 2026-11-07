import Foundation

public struct SystemInspector: Sendable {
    // Retain the native collector so successive snapshots preserve CPU samples.
    private let inventory: InventoryService

    public init() {
        inventory = InventoryService()
    }

    public func snapshot() -> InventorySnapshot {
        inventory.captureSnapshot()
    }
}

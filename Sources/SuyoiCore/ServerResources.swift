import Foundation

/// Totals for unique observed process instances, including across overlapping groups.
public struct ServerResources: Equatable, Sendable {
    public let cpuPercent: Double?
    public let residentBytes: Int64
    /// Nil if any member's footprint is unavailable; RSS is not a footprint substitute.
    public let footprintBytes: Int64?
    public let memberPIDs: [Int]

    public init(processes: [ObservedProcess]) {
        // ProcessIdentity is intentionally not Hashable. This key uses the instance
        // identity (PID + birth time), not the number of listener records.
        struct Key: Hashable { let pid: Int; let started: UInt64? }
        var seen = Set<Key>()
        let unique = processes.filter { seen.insert(Key(pid: $0.pid, started: $0.startTimeMicroseconds)).inserted }
        memberPIDs = Set(unique.map(\.pid)).sorted()
        cpuPercent = unique.isEmpty ? nil : unique.reduce(0) { $0 + $1.cpuPercent }
        residentBytes = unique.reduce(0) { $0 + max(0, $1.residentBytes) }
        footprintBytes = unique.isEmpty || unique.contains(where: { $0.footprintBytes == nil }) ? nil
            : unique.reduce(Int64(0)) { $0 + max(0, $1.footprintBytes ?? 0) }
    }

    public static func aggregate(groups: [ServerGroup], processes: [ObservedProcess]) -> ServerResources {
        let pids = Set(groups.flatMap(\.memberPIDs))
        return ServerResources(processes: processes.filter { pids.contains($0.pid) })
    }
}

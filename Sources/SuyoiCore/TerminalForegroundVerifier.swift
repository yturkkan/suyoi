import Darwin

struct TerminalForegroundVerifier: Sendable {
    var bsdInfo: @Sendable (Int32) -> proc_bsdinfo? = { DarwinProcessReader.bsdInfo(pid: $0) }
    var groupMembers: @Sendable (Int32) -> [Int32]? = { TerminalForegroundVerifier.readGroupMembers($0) }
    var ttyDevice: @Sendable (String) -> UInt32? = { TerminalForegroundVerifier.readTTYDevice($0) }
    var currentUID: @Sendable () -> Int = { Int(getuid()) }

    func verify(agent: AgentObservation, live: ObservedProcess, device: String) -> Bool {
        let identity = live.identity
        guard identity.uid == currentUID(),
              AgentRecognizer.agentName(for: live) == agent.agentName,
              live.agentInvocation == agent.process.agentInvocation,
              let pid = Int32(exactly: identity.pid), pid > 1,
              let start = identity.startTimeMicroseconds,
              let deviceNumber = ttyDevice(device), deviceNumber != 0, deviceNumber != UInt32.max else { return false }

        func isForegroundLeader(_ info: proc_bsdinfo?) -> Bool {
            guard let info else { return false }
            return info.pbi_pid == UInt32(pid)
                && Int(info.pbi_uid) == identity.uid && Int(info.pbi_ruid) == identity.uid
                && info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec == start
                && (info.pbi_status == UInt32(SRUN) || info.pbi_status == UInt32(SSLEEP))
                && info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0
                && info.pbi_flags & UInt32(PROC_FLAG_INEXIT | PROC_FLAG_TRACED) == 0
                && info.e_tdev == deviceNumber
                && info.pbi_pgid == UInt32(pid) && info.e_tpgid == info.pbi_pgid
        }
        return isForegroundLeader(bsdInfo(pid))
            && groupMembers(pid) == [pid]
            && isForegroundLeader(bsdInfo(pid))
    }

    private static func readGroupMembers(_ group: Int32) -> [Int32]? {
        // A second member is enough to reject the whole group, even if the result is truncated.
        var pids = [Int32](repeating: 0, count: 2)
        let written = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), buffer.baseAddress, Int32(buffer.count))
        }
        guard written == MemoryLayout<Int32>.size else { return nil }
        return [pids[0]]
    }

    private static func readTTYDevice(_ path: String) -> UInt32? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFCHR) else { return nil }
        return UInt32(bitPattern: metadata.st_rdev)
    }
}

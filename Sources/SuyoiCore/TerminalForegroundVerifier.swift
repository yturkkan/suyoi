import Darwin
import Foundation

struct TerminalForegroundVerifier: Sendable {
    var bsdInfo: @Sendable (Int32) -> proc_bsdinfo? = { DarwinProcessReader.bsdInfo(pid: $0) }
    var groupMembers: @Sendable (Int32) -> [Int32]? = { TerminalForegroundVerifier.readGroupMembers($0) }
    var ttyDevice: @Sendable (String) -> UInt32? = { TerminalForegroundVerifier.readTTYDevice($0) }
    var currentUID: @Sendable () -> Int = { Int(getuid()) }
    var hasReadableTTY: @Sendable (Int32, UInt32) -> Bool? = {
        TerminalForegroundVerifier.readHasOpenTTYReader(pid: $0, device: $1)
    }

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

        guard isForegroundLeader(bsdInfo(pid)),
              let members = groupMembers(pid),
              !members.isEmpty,
              members.count <= 64 else { return false }

        let uniqueMembers = Set(members)
        guard uniqueMembers.contains(pid) else { return false }

        let otherMembers = uniqueMembers.subtracting([pid])
        if !otherMembers.isEmpty {
            var memberInfos: [Int32: proc_bsdinfo] = [:]
            for memberPID in otherMembers {
                guard memberPID > 1, let info = bsdInfo(memberPID),
                      info.pbi_pid == UInt32(memberPID),
                      Int(info.pbi_uid) == identity.uid,
                      Int(info.pbi_ruid) == identity.uid,
                      info.pbi_pgid == UInt32(pid),
                      info.e_tdev == deviceNumber,
                      info.pbi_flags & UInt32(PROC_FLAG_TRACED) == 0,
                      hasReadableTTY(memberPID, deviceNumber) == false else {
                    return false
                }
                memberInfos[memberPID] = info
            }

            // Every non-leader member must be a verified descendant of the leader within the group.
            for memberPID in otherMembers {
                var current = memberPID
                var visited = Set<Int32>()
                var reachedLeader = false
                while visited.insert(current).inserted, let info = memberInfos[current] {
                    guard let parentPID = Int32(exactly: info.pbi_ppid), parentPID > 1 else { break }
                    if parentPID == pid {
                        reachedLeader = true
                        break
                    }
                    current = parentPID
                }
                guard reachedLeader else { return false }
            }
        }

        return isForegroundLeader(bsdInfo(pid))
    }

    private static func readGroupMembers(_ group: Int32) -> [Int32]? {
        let maxMembers = 64
        var pids = [Int32](repeating: 0, count: maxMembers + 1)
        let written = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), buffer.baseAddress, Int32(buffer.count))
        }
        let stride = MemoryLayout<Int32>.size
        guard written >= stride, Int(written) % stride == 0 else { return nil }
        let count = Int(written) / stride
        guard count <= maxMembers else { return nil }
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private static func readHasOpenTTYReader(pid: Int32, device: UInt32) -> Bool? {
        let capacity = 512
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bytes = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard bytes >= 0, Int(bytes) % stride == 0, Int(bytes) < capacity * stride else { return nil }
        if bytes == 0 {
            return DarwinProcessReader.bsdInfo(pid: pid) == nil ? false : nil
        }
        for descriptor in fds.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var details = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &details, size) == size else {
                if errno == EBADF || errno == ENOENT { continue }
                return nil
            }
            let info = details.pvip.vip_vi.vi_stat
            if UInt16(truncatingIfNeeded: info.vst_mode) & UInt16(truncatingIfNeeded: S_IFMT) == UInt16(truncatingIfNeeded: S_IFCHR),
               UInt32(truncatingIfNeeded: info.vst_rdev) == device,
               details.pfi.fi_openflags & UInt32(FREAD) != 0 {
                return true
            }
        }
        return false
    }

    private static func readTTYDevice(_ path: String) -> UInt32? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFCHR) else { return nil }
        return UInt32(bitPattern: metadata.st_rdev)
    }
}

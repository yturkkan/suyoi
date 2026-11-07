import Foundation
import Darwin

enum ProcessReadOutcome: Sendable {
    case matched(ObservedProcess)
    case otherUser
    case unreadable
}

// A nil PID list indicates that the native enumeration failed; a nil row means
// the process vanished or could not be read between enumeration and inspection.
protocol NativeProcessReading: Sendable {
    func pids() -> [Int32]?
    func process(pid: Int32, uid: Int) -> ObservedProcess?
    func readProcess(pid: Int32, uid: Int) -> ProcessReadOutcome
}

extension NativeProcessReading {
    func readProcess(pid: Int32, uid: Int) -> ProcessReadOutcome {
        guard let row = process(pid: pid, uid: uid) else { return .unreadable }
        return .matched(row)
    }
}

struct DarwinProcessReader: NativeProcessReading {
    func pids() -> [Int32]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let written = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return nil }
        return Array(pids.prefix(Int(written))).filter { $0 > 0 }
    }
    func readProcess(pid: Int32, uid: Int) -> ProcessReadOutcome {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout<proc_bsdinfo>.size else {
            return errno == EPERM ? .otherUser : .unreadable
        }
        guard Int(bsd.pbi_uid) == uid else { return .otherUser }
        guard let row = process(pid: pid, uid: uid) else { return .unreadable }
        return .matched(row)
    }
    func process(pid: Int32, uid: Int) -> ObservedProcess? {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout<proc_bsdinfo>.size,
              Int(bsd.pbi_uid) == uid else { return nil }
        let name = withUnsafePointer(to: &bsd.pbi_comm) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) } }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathSize = proc_pidpath(pid, &path, UInt32(path.count))
        let argReader = ProcessArgumentsReader()
        let executable: String
        if pathSize > 0 {
            executable = String(cString: path)
        } else if let fallbackExec = argReader.executablePath(pid: pid) {
            executable = fallbackExec
        } else {
            executable = name
        }
        var vnode = proc_vnodepathinfo()
        var cwd: String?
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode))) == MemoryLayout<proc_vnodepathinfo>.size {
            cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            if cwd?.isEmpty == true { cwd = nil }
        }
        var tty: String?
        if bsd.e_tdev != 0 && bsd.e_tdev != UInt32.max, let device = devname(dev_t(bitPattern: bsd.e_tdev), mode_t(S_IFCHR)) {
            let value = String(cString: device)
            tty = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        }
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        var footprint: Int64?, cpu: UInt64?
        var resident: Int64 = 0
        if usageResult == 0 {
            footprint = Int64(clamping: usage.ri_phys_footprint)
            resident = Int64(clamping: usage.ri_resident_size)
            var timebase = mach_timebase_info_data_t()
            if mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0 {
                let (ticks, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
                if !overflow {
                    let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
                    if product.high < UInt64(timebase.denom) { cpu = UInt64(timebase.denom).dividingFullWidth(product).quotient }
                }
            }
        }
        return ObservedProcess(pid: Int(pid), parentPID: Int(bsd.pbi_ppid), uid: uid, cpuPercent: 0, residentBytes: resident, executable: executable, startTimeMicroseconds: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec, cwd: cwd, tty: tty, isStopped: bsd.pbi_status == UInt32(SSTOP), footprintBytes: footprint, cpuNanoseconds: cpu, agentInvocation: argReader.invocation(pid: pid, executablePath: executable))
    }
}

public final class NativeProcessInspector: ProcessInspecting, @unchecked Sendable {
    private let reader: any NativeProcessReading
    private let runner: (any CommandRunning)?
    private let lock = NSLock()
    private var previous: [Int: (ProcessIdentity, UInt64, UInt64)] = [:]
    public init(runner: (any CommandRunning)? = CommandRunner()) { self.reader = DarwinProcessReader(); self.runner = runner }
    init(reader: any NativeProcessReading, runner: (any CommandRunning)? = nil) { self.reader = reader; self.runner = runner }

    static func cpuPercent(previous: (ProcessIdentity, UInt64, UInt64)?, identity: ProcessIdentity, cpu: UInt64?, wall: UInt64) -> Double {
        guard let previous, let cpu, identity.startTimeMicroseconds != nil, previous.0 == identity, cpu >= previous.1, wall > previous.2 else { return 0 }
        return Double(cpu - previous.1) / Double(wall - previous.2) * 100
    }
    public func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), wall = DispatchTime.now().uptimeNanoseconds
        guard let pids = reader.pids() else { return fallback(uid: uid, now: now) }
        var rows: [ObservedProcess] = [], missed = 0
        var next: [Int: (ProcessIdentity, UInt64, UInt64)] = [:]
        for pid in pids {
            let row: ObservedProcess
            switch reader.readProcess(pid: pid, uid: uid) {
            case .matched(let matched):
                row = matched
            case .otherUser:
                continue
            case .unreadable:
                missed += 1
                continue
            }
            let percent = Self.cpuPercent(previous: previous[row.pid], identity: row.identity, cpu: row.cpuNanoseconds, wall: wall)
            if let cpu = row.cpuNanoseconds { next[row.pid] = (row.identity, cpu, wall) }
            rows.append(ObservedProcess(pid: row.pid, parentPID: row.parentPID, uid: row.uid, cpuPercent: percent, residentBytes: row.residentBytes, executable: row.executable, startTimeMicroseconds: row.startTimeMicroseconds, cwd: row.cwd, tty: row.tty, isStopped: row.isStopped, footprintBytes: row.footprintBytes, cpuNanoseconds: row.cpuNanoseconds, agentInvocation: row.agentInvocation))
        }
        previous = next
        let partial = missed > 0 || rows.contains { $0.startTimeMicroseconds == nil }
        return Observation(value: rows.sorted { $0.pid < $1.pid }, status: partial ? .partial : .complete, warnings: partial ? ["Some processes vanished, were inaccessible, or have incomplete metadata."] : [], capturedAt: now)
    }
    private func fallback(uid: Int, now: Date) -> Observation<[ObservedProcess]> {
        previous = [:]
        guard let runner else { return Observation(value: [], status: .unavailable, warnings: ["Native process enumeration failed; fallback unavailable."], capturedAt: now) }
        do {
            let result = try runner.run(CommandRequest(executable: "/bin/ps", arguments: ["-U", String(uid), "-o", "pid=,ppid=,uid=,pcpu=,rss=,comm="]))
            let fallbackRows = InventoryParser.processes(result.stdoutText, uid: uid)
            let rows = fallbackRows.map { fallback -> ObservedProcess in
                guard let native = reader.process(pid: Int32(clamping: fallback.pid), uid: uid) else { return fallback }
                return ObservedProcess(pid: native.pid, parentPID: native.parentPID, uid: native.uid, cpuPercent: fallback.cpuPercent, residentBytes: native.footprintBytes == nil ? fallback.residentBytes : native.residentBytes, executable: native.executable.hasPrefix("/") ? native.executable : fallback.executable, startTimeMicroseconds: native.startTimeMicroseconds, cwd: native.cwd, tty: native.tty, isStopped: native.isStopped, footprintBytes: native.footprintBytes, cpuNanoseconds: native.cpuNanoseconds, agentInvocation: native.agentInvocation)
            }
            let warning = "Native process enumeration failed; ps fallback may be incomplete."
            guard !rows.isEmpty else { return Observation(value: [], status: .unavailable, warnings: [warning], capturedAt: now) }
            return Observation(value: rows, status: .partial, warnings: [warning], capturedAt: now)
        } catch { return Observation(value: [], status: .unavailable, warnings: ["Native process enumeration and ps fallback failed: \(error.localizedDescription)"], capturedAt: now) }
    }
}

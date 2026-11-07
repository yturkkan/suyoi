import Foundation

public enum InventoryParser {
    // ps comm contains an executable path, not arguments or environment data.
    public static func processes(_ text: String, uid: Int) -> [ObservedProcess] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 6, let pid = Int(fields[0]), pid > 0,
                  let parent = Int(fields[1]), parent >= 0, let owner = Int(fields[2]), owner == uid,
                  let cpu = Double(fields[3]), cpu.isFinite, cpu >= 0,
                  let rss = Int64(fields[4]), rss >= 0, rss <= Int64.max / 1024 else { return nil }
            let path = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return ObservedProcess(pid: pid, parentPID: parent, uid: owner, cpuPercent: cpu, residentBytes: rss * 1024, executable: path)
        }
    }

    public static func listeners(_ text: String) -> [Listener] {
        var pid: Int?
        var processName: String?
        var result: [Listener] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value); processName = nil
            case "c": processName = value
            case "n":
                guard let pid, pid > 0, let processName, !processName.isEmpty,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { continue }
                let address = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                guard !address.isEmpty else { continue }
                let row = Listener(pid: pid, processName: processName, address: address, port: port)
                if seen.insert(row.id).inserted { result.append(row) }
            default: continue
            }
        }
        return result.sorted { ($0.port, $0.pid, $0.address) < ($1.port, $1.pid, $1.address) }
    }
}

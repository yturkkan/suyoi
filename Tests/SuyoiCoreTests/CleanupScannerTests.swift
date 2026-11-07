import Foundation
import Testing
@testable import SuyoiCore

@Suite struct CleanupScannerBudgetTests {
    @Test func discoveryPrecedesFairMeasurement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        for (project, count) in [("A", 500), ("B", 10)] {
            let directory = root.appendingPathComponent("\(project)/node_modules")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<count { try Data([1]).write(to: directory.appendingPathComponent("\(index)")) }
        }
        let report = CleanupScanner().scan(root: root, entryLimit: 120)
        #expect(report.discoveredCount == 2)
        #expect(report.candidates.count == 2)
        let large = report.candidates.first { $0.path.hasSuffix("/A/node_modules") }
        let small = report.candidates.first { $0.path.hasSuffix("/B/node_modules") }
        #expect(large?.partial == true)
        #expect(small?.bytes == 10)
        #expect(report.partial)
        #expect(large?.fileIdentity != nil)
        #expect(large?.allocatedBytes != nil)
        #expect(large?.fileIdentity == FileMetadataReader().identity(at: root.appendingPathComponent("A/node_modules")))
    }
}

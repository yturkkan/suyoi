import Foundation
import Darwin
import Testing
@testable import SuyoiCore

@Suite("Chiptune waveforms and built-in sound pack")
struct ChiptuneWaveformGeneratorTests {
    @Test(arguments: SuyoiAudioEvent.allCases, SuyoiExperienceTheme.allCases)
    func validNonSilentPCM(event: SuyoiAudioEvent, theme: SuyoiExperienceTheme) throws {
        let wav = ChiptuneWaveformGenerator.wavData(for: event, theme: theme)
        let samples = try validateWAV(wav, sampleRate: 22_050)
        #expect(samples.count > 2_205)
        #expect(samples.count < 22_050)
        #expect(samples.contains { $0 > 100 })
        #expect(samples.contains { $0 < -100 })
        #expect(samples.allSatisfy { abs(Int($0)) < Int(Int16.max) })
        #expect(samples.first == 0)
        #expect(samples.last == 0)
        #expect(wav == ChiptuneWaveformGenerator.wavData(for: event, theme: theme))
    }

    @Test(arguments: SuyoiExperienceTheme.allCases)
    func eventsHaveDistinctPayloads(theme: SuyoiExperienceTheme) {
        let payloads = SuyoiAudioEvent.allCases.map {
            ChiptuneWaveformGenerator.wavData(for: $0, theme: theme).dropFirst(44)
        }
        #expect(Set(payloads).count == SuyoiAudioEvent.allCases.count)
    }

    @Test(arguments: SuyoiAudioEvent.allCases)
    func themesHaveDistinctTimbres(event: SuyoiAudioEvent) {
        let waves = SuyoiExperienceTheme.allCases.map {
            ChiptuneWaveformGenerator.wavData(for: event, theme: $0)
        }
        #expect(Set(waves.map { $0.dropFirst(44) }).count == SuyoiExperienceTheme.allCases.count)
        #expect(Set(waves.map(\.count)).count == 1)
    }

    @Test(arguments: [8_000, 22_050, 44_100, 48_000, 96_000, 192_000])
    func customSampleRateIsEncodedAndPreservesDuration(sampleRate: Int) throws {
        for event in SuyoiAudioEvent.allCases {
            let wav = ChiptuneWaveformGenerator.wavData(for: event, theme: .nativeGlass, sampleRate: sampleRate)
            let samples = try validateWAV(wav, sampleRate: sampleRate)
            let reference = ChiptuneWaveformGenerator.wavData(for: event, theme: .nativeGlass)
            let duration = Double(samples.count) / Double(sampleRate)
            let referenceDuration = Double((reference.count - 44) / 2) / 22_050
            #expect(abs(duration - referenceDuration) < 0.001)
            #expect(samples.contains { $0 != 0 })
        }
    }

    @Test(arguments: [Int.min, -1, 0, 192_001, Int.max])
    func invalidRatesUseDefault(sampleRate: Int) {
        #expect(ChiptuneWaveformGenerator.wavData(for: .taskCompleted, theme: .pixelArcade, sampleRate: sampleRate)
            == ChiptuneWaveformGenerator.wavData(for: .taskCompleted, theme: .pixelArcade))
    }

    @Test func installationProducesCompleteDiscoverablePack() throws {
        try withDirectory { home in
            let pack = try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
            let directory = home.appendingPathComponent(".openpeon/packs/suyoi-retro-8bit", isDirectory: true)
            #expect(pack.name == "suyoi-retro-8bit")
            #expect(pack.displayName == "Suyoi Retro 8-Bit (Built-in)")
            #expect(pack.directoryPath == directory.path)
            #expect(pack.id == directory.path)
            #expect(Set(pack.eventSoundPaths.keys) == Set(SuyoiAudioEvent.allCases))
            #expect(ExperienceThemeCatalog.loadSoundPack(at: directory) == pack)
            #expect(ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home) == [pack])

            let manifestData = try Data(contentsOf: directory.appendingPathComponent("openpeon.json"))
            let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            #expect(manifest["cesp_version"] as? String == "1.0")
            #expect(manifest["version"] as? String == "1.0.0")
            #expect(manifest["name"] as? String == pack.name)
            #expect(manifest["display_name"] as? String == pack.displayName)
            let categories = try #require(manifest["categories"] as? [String: Any])
            let mappings: [(SuyoiAudioEvent, String)] = [
                (.sessionStarted, "session.start"), (.attentionRequired, "input.required"),
                (.taskCompleted, "task.complete"), (.taskError, "task.error"), (.quotaWarning, "resource.limit")
            ]
            #expect(Set(categories.keys) == Set(mappings.map { $0.1 }))
            for (event, categoryName) in mappings {
                let path = try #require(pack.eventSoundPaths[event])
                #expect(path.hasPrefix("sounds/"))
                #expect(path.hasSuffix(".wav"))
                let category = try #require(categories[categoryName] as? [String: Any])
                let sounds = try #require(category["sounds"] as? [[String: String]])
                #expect(sounds.count == 1)
                #expect(sounds.first?["file"] == path)
                let wav = try Data(contentsOf: directory.appendingPathComponent(path))
                _ = try validateWAV(wav, sampleRate: 22_050)
                #expect(wav == ChiptuneWaveformGenerator.wavData(for: event, theme: .pixelArcade))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["openpeon.json", "sounds"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("sounds").path).count == 5)
        }
    }

    @Test func repeatedInstallationRefreshesOnlyBuiltInFiles() throws {
        try withDirectory { home in
            let first = try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
            let directory = URL(fileURLWithPath: first.directoryPath, isDirectory: true)
            let customFile = directory.appendingPathComponent("keep.txt")
            let marker = Data("preserved".utf8)
            try marker.write(to: customFile)
            let path = try #require(first.eventSoundPaths[.taskCompleted])
            try Data("damaged".utf8).write(to: directory.appendingPathComponent(path))
            let second = try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
            #expect(second == first)
            #expect(try Data(contentsOf: customFile) == marker)
            #expect(try Data(contentsOf: directory.appendingPathComponent(path))
                == ChiptuneWaveformGenerator.wavData(for: .taskCompleted, theme: .pixelArcade))
        }
    }

    @Test(arguments: [".openpeon", ".openpeon/packs", ".openpeon/packs/suyoi-retro-8bit",
                      ".openpeon/packs/suyoi-retro-8bit/sounds"])
    func installationRejectsSymlinkedDirectories(path: String) throws {
        try withDirectory { home in
            let external = home.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let link = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            #expect(throws: (any Error).self) {
                try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        }
    }

    @Test func installationRejectsSymlinkedHomeAndAncestor() throws {
        try withDirectory { root in
            let real = root.appendingPathComponent("real/home", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let homeLink = root.appendingPathComponent("home-link", isDirectory: true)
            let ancestorLink = root.appendingPathComponent("ancestor-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: real)
            try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: real.deletingLastPathComponent())
            for home in [homeLink, ancestorLink.appendingPathComponent("home", isDirectory: true)] {
                #expect(throws: (any Error).self) {
                    try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
        }
    }

    @Test(arguments: ["openpeon.json", "sounds/session-started.wav", "sounds/attention-required.wav",
                      "sounds/task-completed.wav", "sounds/task-error.wav", "sounds/quota-warning.wav"])
    func installationRejectsSymlinkedFiles(path: String) throws {
        try withDirectory { home in
            let directory = home.appendingPathComponent(".openpeon/packs/suyoi-retro-8bit", isDirectory: true)
            let link = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = home.appendingPathComponent("untouched")
            let marker = Data("preserved".utf8)
            try marker.write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: (any Error).self) {
                try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
            }
            #expect(try Data(contentsOf: target) == marker)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        }
    }

    @Test func installationRejectsDanglingLinksAndNonRegularFiles() throws {
        try withDirectory { root in
            for kind in ["dangling", "directory", "fifo", "hardlink"] {
                let home = root.appendingPathComponent(kind, isDirectory: true)
                let directory = home.appendingPathComponent(".openpeon/packs/suyoi-retro-8bit", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("openpeon.json")
                switch kind {
                case "dangling":
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: home.appendingPathComponent("missing"))
                case "directory":
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                case "fifo":
                    #expect(mkfifo(destination.path, 0o600) == 0)
                default:
                    let target = home.appendingPathComponent("original")
                    try Data("preserved".utf8).write(to: target)
                    try FileManager.default.linkItem(at: target, to: destination)
                }
                #expect(throws: (any Error).self) {
                    try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: home)
                }
                if kind == "hardlink" {
                    #expect(try Data(contentsOf: home.appendingPathComponent("original")) == Data("preserved".utf8))
                }
            }
        }
    }

    @Test func installationRejectsNonFileHome() throws {
        let remote = try #require(URL(string: "https://example.test/home"))
        #expect(throws: (any Error).self) {
            try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: remote)
        }
    }

    private func validateWAV(_ data: Data, sampleRate: Int) throws -> [Int16] {
        try #require(data.count >= 44)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(integer(data, at: 4, bytes: 4) == UInt32(data.count - 8))
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "fmt ")
        #expect(integer(data, at: 16, bytes: 4) == 16)
        #expect(integer(data, at: 20, bytes: 2) == 1)
        #expect(integer(data, at: 22, bytes: 2) == 1)
        #expect(integer(data, at: 24, bytes: 4) == UInt32(sampleRate))
        #expect(integer(data, at: 28, bytes: 4) == UInt32(sampleRate * 2))
        #expect(integer(data, at: 32, bytes: 2) == 2)
        #expect(integer(data, at: 34, bytes: 2) == 16)
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(integer(data, at: 40, bytes: 4) == UInt32(data.count - 44))
        try #require((data.count - 44).isMultiple(of: 2))
        return stride(from: 44, to: data.count, by: 2).map {
            Int16(bitPattern: UInt16(integer(data, at: $0, bytes: 2)))
        }
    }

    private func integer(_ data: Data, at offset: Int, bytes: Int) -> UInt32 {
        (0..<bytes).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (8 * $1)) }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("suyoi-chiptune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

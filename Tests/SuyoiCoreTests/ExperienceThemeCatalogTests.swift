import Foundation
import Darwin
import Testing
@testable import SuyoiCore

@Suite("Experience themes and sound packs")
struct ExperienceThemeCatalogTests {
    @Test func publicEnumValuesAndCodableRoundTrips() throws {
        #expect(SuyoiExperienceTheme.allCases.map(\.rawValue) == ["Suyoi Glass", "macOS Native", "Pixel Arcade", "Game Boy Olive"])
        #expect(SuyoiSurfaceMode.allCases.map(\.rawValue) == ["Menu Bar Popover", "Notch Dynamic Island", "Floating Companion"])
        #expect(SuyoiAudioEvent.allCases.map(\.rawValue) == ["Session Started", "Attention Required", "Task Completed", "Task Error", "Quota Warning"])
        #expect(SuyoiSoundMode.allCases.map(\.rawValue) == ["Muted", "macOS System Sounds", "OpenPeon Sound Pack"])
        try roundTrip(SuyoiExperienceTheme.allCases)
        try roundTrip(SuyoiSurfaceMode.allCases)
        try roundTrip(SuyoiAudioEvent.allCases)
        try roundTrip(SuyoiSoundMode.allCases)
        try roundTrip([MascotAnimationState.working, .waitingForApproval, .idle, .completed, .sleeping])
    }

    @Test(arguments: SuyoiExperienceTheme.allCases)
    func themeTokensAreValidAndDeterministic(theme: SuyoiExperienceTheme) {
        let tokens = ExperienceThemeCatalog.tokens(for: theme)
        #expect(tokens.theme == theme)
        #expect(tokens == ExperienceThemeCatalog.tokens(for: theme))
        for component in [tokens.accentRed, tokens.accentGreen, tokens.accentBlue] {
            #expect(component.isFinite && (0...1).contains(component))
        }
        switch theme {
        case .nativeGlass, .macOSSystem:
            #expect(!tokens.usesMonospacedChrome)
            #expect(tokens.cornerRadius >= 12)
            #expect(tokens.recommendedSoundMode == .systemSounds)
            #expect(tokens.accentBlue > tokens.accentGreen)
        case .pixelArcade, .pixelOlive:
            #expect(tokens.usesMonospacedChrome)
            #expect((0...4).contains(tokens.cornerRadius))
            #expect(tokens.recommendedSoundMode == .soundPack)
        }
        if theme == .pixelOlive {
            #expect(tokens.accentGreen > tokens.accentRed)
            #expect(tokens.accentRed > tokens.accentBlue)
        }
    }

    @Test func themesHaveDistinctPalettes() {
        let palettes = SuyoiExperienceTheme.allCases.map { theme in
            let tokens = ExperienceThemeCatalog.tokens(for: theme)
            return [tokens.accentRed, tokens.accentGreen, tokens.accentBlue]
        }
        #expect(Set(palettes).count == SuyoiExperienceTheme.allCases.count)
    }

    @Test func systemSoundsCoverEveryEventAndTheme() {
        let expected: [SuyoiExperienceTheme: [String]] = [
            .nativeGlass: ["Tink", "Ping", "Glass", "Basso", "Sosumi"],
            .macOSSystem: ["Tink", "Ping", "Glass", "Basso", "Sosumi"],
            .pixelArcade: ["Tink", "Ping", "Hero", "Basso", "Sosumi"],
            .pixelOlive: ["Pop", "Morse", "Glass", "Basso", "Bottle"]
        ]
        for theme in SuyoiExperienceTheme.allCases {
            #expect(SuyoiAudioEvent.allCases.map { ExperienceThemeCatalog.systemSoundName(for: $0, theme: theme) } == expected[theme])
        }
    }

    @Test func mascotUsesStructuredActivityOnly() {
        #expect(ExperienceThemeCatalog.mascotState(for: agent(.active)) == .working)
        #expect(ExperienceThemeCatalog.mascotState(for: agent(.waiting)) == .waitingForApproval)
        #expect(ExperienceThemeCatalog.mascotState(for: agent(.idle)) == .idle)
        #expect(ExperienceThemeCatalog.mascotState(for: agent(nil)) == .idle)
        #expect(ExperienceThemeCatalog.mascotState(for: agent(.stopped)) == .sleeping)
        // Free-form task text cannot establish a completion event.
        #expect(ExperienceThemeCatalog.mascotState(for: agent(.idle, task: "Task completed")) == .idle)
    }

    @Test func approvalAndStoppedPrecedence() {
        for state: AgentActivityState? in [.active, .waiting, .idle, nil] {
            #expect(ExperienceThemeCatalog.mascotState(for: agent(state), hasPendingApproval: true) == .waitingForApproval)
            #expect(ExperienceThemeCatalog.mascotState(for: agent(state, stopped: true), hasPendingApproval: true) == .sleeping)
            #expect(ExperienceThemeCatalog.mascotState(for: agent(state, stopped: true)) == .sleeping)
        }
        #expect(ExperienceThemeCatalog.mascotState(for: agent(.stopped), hasPendingApproval: true) == .sleeping)
    }

    @Test func cespManifestMapsAllEventsAndRoundTripsPack() throws {
        try withDirectory { root in
            let files = ["sounds/start.wav", "sounds/attention.mp3", "sounds/complete.ogg", "sounds/error.aiff", "sounds/quota.m4a"]
            let categories = Dictionary(uniqueKeysWithValues: zip(
                ["session.start", "input.required", "task.complete", "task.error", "resource.limit"], files.map { [$0] }))
            try writePack(at: root, categories: categories, files: files)
            let pack = try #require(ExperienceThemeCatalog.loadSoundPack(at: root))
            #expect(pack.name == "test-pack")
            #expect(pack.displayName == "Test Pack")
            #expect(pack.directoryPath == root.path)
            #expect(pack.id == root.path)
            #expect(pack.eventSoundPaths == Dictionary(uniqueKeysWithValues: zip(SuyoiAudioEvent.allCases, files)))
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == pack)
            try roundTrip([pack])
        }
    }

    @Test(arguments: ["wav", "mp3", "ogg", "aiff", "m4a", "caf", "WAV", "Mp3"])
    func supportedExtensionsAndUnicodePaths(fileExtension: String) throws {
        try withDirectory { root in
            let path = "sounds/nested/Ready café.\(fileExtension)"
            try writePack(at: root, categories: ["task.acknowledge": [path]], files: [path])
            let pack = try #require(ExperienceThemeCatalog.loadSoundPack(at: root))
            #expect(pack.eventSoundPaths == [.sessionStarted: path])
        }
    }

    @Test func sessionStartHasPriorityAndAcknowledgementIsFallback() throws {
        try withDirectory { root in
            let start = "sounds/start.wav", acknowledge = "sounds/ack.wav"
            try writePack(at: root, categories: ["task.acknowledge": [acknowledge], "session.start": [start]], files: [start, acknowledge])
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root)?.eventSoundPaths[.sessionStarted] == start)
            try writePack(at: root, categories: ["session.start": ["../escape.wav"], "task.acknowledge": [acknowledge]])
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root)?.eventSoundPaths[.sessionStarted] == acknowledge)
        }
    }

    @Test func firstUsableSoundWinsAndInvalidEntriesAreSkipped() throws {
        try withDirectory { root in
            try writeAudio("sounds/first.wav", at: root)
            try writeAudio("sounds/second.wav", at: root)
            try writeManifest([
                "name": "partial", "categories": [
                    "task.complete": ["sounds": [NSNull(), "not-an-object", ["file": 7], ["file": "missing.wav"],
                        ["file": "sounds/first.wav"], ["file": "sounds/second.wav"]]],
                    "input.required": ["sounds": "invalid"],
                    "task.error": [],
                    "unknown.event": ["sounds": [["file": "sounds/second.wav"]]]
                ]
            ], at: root)
            let pack = try #require(ExperienceThemeCatalog.loadSoundPack(at: root))
            #expect(pack.eventSoundPaths == [.taskCompleted: "sounds/first.wav"])
            #expect(pack.displayName == "partial")
        }
    }

    @Test func metadataIsTrimmedAndDisplayNameFallsBack() throws {
        try withDirectory { root in
            try writeAudio("cue.wav", at: root)
            for display: Any in ["  ", NSNull(), 42, "bad\u{001B}name", String(repeating: "x", count: 257)] {
                try writeManifest(["name": "  pack  ", "display_name": display,
                    "categories": ["session.start": ["sounds": [["file": "cue.wav"]]]]], at: root)
                let pack = try #require(ExperienceThemeCatalog.loadSoundPack(at: root))
                #expect(pack.name == "pack")
                #expect(pack.displayName == "pack")
            }
        }
    }

    @Test func missingMalformedAndUnusableManifestsAreRejected() throws {
        try withDirectory { root in
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
            for bytes in [Data(), Data("{broken".utf8), Data("[]".utf8), Data(repeating: 32, count: 1_048_577)] {
                try bytes.write(to: root.appendingPathComponent("openpeon.json"))
                #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
            }
            let manifests: [[String: Any]] = [
                [:], ["name": "pack"], ["name": "pack", "categories": []],
                ["name": "pack", "categories": [:]],
                ["name": "pack", "categories": ["unknown": ["sounds": [["file": "cue.wav"]]]]],
                ["categories": ["session.start": ["sounds": [["file": "cue.wav"]]]]]
            ]
            try writeAudio("cue.wav", at: root)
            for manifest in manifests {
                try writeManifest(manifest, at: root)
                #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
            }
            for name: Any in ["", "   ", 42, "bad\u{0000}name", String(repeating: "x", count: 257)] {
                try writeManifest(["name": name, "categories": ["session.start": ["sounds": [["file": "cue.wav"]]]]], at: root)
                #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
            }
        }
    }

    @Test(arguments: ["../escape.wav", "sounds/../../escape.wav", "sounds/../cue.wav", "/escape.wav", "~/cue.wav",
        "sounds\\cue.wav", "sounds//cue.wav", "./cue.wav", "sounds/./cue.wav", "https://example.test/cue.wav",
        "cue.wav\u{0000}", "cue\n.wav", "", "cue.txt", "cue", "cue.flac"])
    func unsafeOrUnsupportedPathsAreRejected(path: String) throws {
        try withDirectory { root in
            // Valid files ensure traversal rejection is independent of target existence.
            try writeAudio("cue.wav", at: root)
            try writeAudio("sounds/cue.wav", at: root)
            try writePack(at: root, categories: ["task.complete": [path]])
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
        }
    }

    @Test func existingTraversalTargetsAndAbsolutePathsAreRejected() throws {
        try withDirectory { root in
            let pack = root.appendingPathComponent("pack")
            try writeAudio("outside.wav", at: root)
            for path in ["../outside.wav", root.appendingPathComponent("outside.wav").path] {
                try writePack(at: pack, categories: ["task.complete": [path]])
                #expect(ExperienceThemeCatalog.loadSoundPack(at: pack) == nil)
            }
        }
    }

    @Test func missingFilesDirectoriesAndFIFOsAreRejected() throws {
        try withDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.wav"), withIntermediateDirectories: true)
            let fifo = root.appendingPathComponent("pipe.wav")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            for path in ["missing.wav", "directory.wav", "pipe.wav"] {
                try writePack(at: root, categories: ["task.complete": [path]])
                #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
            }
        }
    }

    @Test func symlinkedAudioFilesAndDirectoriesAreRejected() throws {
        try withDirectory { root in
            let pack = root.appendingPathComponent("pack")
            try writePack(at: pack, categories: [:], files: ["real/cue.wav"])
            try writeAudio("external/cue.wav", at: root)
            let links = [
                ("linked.wav", pack.appendingPathComponent("real/cue.wav")),
                ("external.wav", root.appendingPathComponent("external/cue.wav")),
                ("linked-directory", pack.appendingPathComponent("real")),
                ("external-directory", root.appendingPathComponent("external"))
            ]
            for (name, target) in links {
                try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent(name), withDestinationURL: target)
            }
            for path in ["linked.wav", "external.wav", "linked-directory/cue.wav", "external-directory/cue.wav"] {
                try writePack(at: pack, categories: ["task.complete": [path]])
                #expect(ExperienceThemeCatalog.loadSoundPack(at: pack) == nil)
            }
            try writePack(at: pack, categories: ["task.complete": ["linked.wav", "real/cue.wav"]])
            #expect(ExperienceThemeCatalog.loadSoundPack(at: pack)?.eventSoundPaths[.taskCompleted] == "real/cue.wav")
        }
    }

    @Test func symlinkedPackRootsAncestorsAndManifestAreRejected() throws {
        try withDirectory { root in
            let pack = root.appendingPathComponent("real/pack")
            try writePack(at: pack, categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            let packLink = root.appendingPathComponent("pack-link")
            try FileManager.default.createSymbolicLink(at: packLink, withDestinationURL: pack)
            #expect(ExperienceThemeCatalog.loadSoundPack(at: packLink) == nil)
            let ancestorLink = root.appendingPathComponent("ancestor-link")
            try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: root.appendingPathComponent("real"))
            #expect(ExperienceThemeCatalog.loadSoundPack(at: ancestorLink.appendingPathComponent("pack")) == nil)
            let manifest = pack.appendingPathComponent("openpeon.json")
            let relocated = root.appendingPathComponent("manifest.json")
            try FileManager.default.moveItem(at: manifest, to: relocated)
            try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: relocated)
            #expect(ExperienceThemeCatalog.loadSoundPack(at: pack) == nil)
        }
    }

    @Test func nonRegularManifestsAndNonFileURLsAreRejected() throws {
        try withDirectory { root in
            let manifest = root.appendingPathComponent("openpeon.json")
            #expect(mkfifo(manifest.path, 0o600) == 0)
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root) == nil)
            #expect(ExperienceThemeCatalog.loadSoundPack(at: root.appendingPathComponent("missing")) == nil)
            #expect(ExperienceThemeCatalog.loadSoundPack(at: manifest) == nil)
            let directoryManifest = root.appendingPathComponent("directory-manifest")
            try FileManager.default.createDirectory(at: directoryManifest.appendingPathComponent("openpeon.json"), withIntermediateDirectories: true)
            #expect(ExperienceThemeCatalog.loadSoundPack(at: directoryManifest) == nil)
        }
        let remote = try #require(URL(string: "https://example.test/pack"))
        #expect(ExperienceThemeCatalog.loadSoundPack(at: remote) == nil)
        #expect(ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: remote).isEmpty)
    }

    @Test func discoveryScansBothRootsAndKeepsDuplicateNamesDistinct() throws {
        try withDirectory { home in
            let first = home.appendingPathComponent(".openpeon/packs/first")
            let second = home.appendingPathComponent(".claude/hooks/peon-ping/packs/second")
            try writePack(at: first, name: "same-name", displayName: "Zulu", categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            try writePack(at: second, name: "same-name", displayName: "Alpha", categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            try writePack(at: home.appendingPathComponent(".openpeon/packs/invalid"), categories: [:])
            try writePack(at: first.appendingPathComponent("nested"), categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            let link = home.appendingPathComponent(".openpeon/packs/linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
            try Data("ignored".utf8).write(to: home.appendingPathComponent(".openpeon/packs/plain-file"))
            let packs = ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home)
            #expect(packs.map(\.displayName) == ["Alpha", "Zulu"])
            #expect(packs.map(\.directoryPath) == [second.path, first.path])
            #expect(Set(packs.map(\.id)).count == 2)
            #expect(ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home) == packs)
        }
    }

    @Test func discoveryTiesUseStablePathOrder() throws {
        try withDirectory { home in
            for name in ["b", "a"] {
                try writePack(at: home.appendingPathComponent(".openpeon/packs/\(name)"),
                    categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            }
            let packs = ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home)
            #expect(packs.map { URL(fileURLWithPath: $0.directoryPath).lastPathComponent } == ["a", "b"])
        }
    }

    @Test func discoveryHandlesMissingRootsAndRejectsSymlinkedRoots() throws {
        try withDirectory { home in
            #expect(ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home).isEmpty)
            let external = home.appendingPathComponent("external")
            try writePack(at: external.appendingPathComponent("pack"), categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            let openPeon = home.appendingPathComponent(".openpeon")
            try FileManager.default.createDirectory(at: openPeon, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: openPeon.appendingPathComponent("packs"), withDestinationURL: external)
            #expect(ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home).isEmpty)
            let claude = home.appendingPathComponent(".claude")
            try writePack(at: external.appendingPathComponent("peon-ping/packs/hidden"),
                categories: ["task.complete": ["cue.wav"]], files: ["cue.wav"])
            try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("hooks"), withDestinationURL: external)
            #expect(ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home).isEmpty)
        }
    }

    private func agent(_ state: AgentActivityState?, stopped: Bool = false, task: String? = nil) -> AgentObservation {
        AgentObservation(id: 42, agentName: "Codex",
            process: ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0,
                executable: "/usr/local/bin/codex", isStopped: stopped),
            project: nil, terminalApp: nil, statusSource: .processOnly, childServerPorts: [],
            activityState: state, currentTask: task)
    }

    private func roundTrip<Value: Codable & Equatable>(_ values: [Value]) throws {
        let encoded = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([Value].self, from: encoded) == values)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("suyoi-themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writePack(at root: URL, name: String = "test-pack", displayName: String = "Test Pack",
                           categories: [String: [String]], files: [String] = []) throws {
        for file in files { try writeAudio(file, at: root) }
        let entries = categories.mapValues { paths in ["sounds": paths.map { ["file": $0] }] }
        try writeManifest(["cesp_version": "1.0", "name": name, "display_name": displayName,
            "version": "1.0.0", "categories": entries], at: root)
    }

    private func writeManifest(_ manifest: [String: Any], at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("openpeon.json"))
    }

    private func writeAudio(_ path: String, at root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: file)
    }
}

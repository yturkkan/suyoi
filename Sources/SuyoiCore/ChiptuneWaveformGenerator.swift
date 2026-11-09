import Foundation
import Darwin

/// Small, deterministic notification cues synthesized without audio resources or playback.
public enum ChiptuneWaveformGenerator {
    /// Returns 16-bit mono PCM. Unsupported rates outside 1...192,000 Hz use 22,050 Hz.
    public static func wavData(for event: SuyoiAudioEvent, theme: SuyoiExperienceTheme,
                               sampleRate: Int = 22_050) -> Data {
        let rate = (1...192_000).contains(sampleRate) ? sampleRate : 22_050
        let melody = notes(for: event)
        var pcm = Data()
        for (index, note) in melody.enumerated() {
            let count = max(3, Int(note.duration * Double(rate)))
            let frequency = 440 * pow(2, Double(note.midi - 69) / 12)
            for sample in 0..<count {
                let time = Double(sample) / Double(rate)
                let progress = Double(sample) / Double(count - 1)
                let phase = (time * frequency).truncatingRemainder(dividingBy: 1)
                let wave: Double
                let decay: Double
                switch theme {
                case .pixelArcade, .pixelOlive:
                    let duty = theme == .pixelArcade ? 0.5 : 0.25
                    // Balance pulse area to avoid a DC offset at narrower duty cycles.
                    wave = phase < duty ? 1 : -duty / (1 - duty)
                    decay = 1 - 0.45 * progress
                case .nativeGlass, .macOSSystem:
                    let angle = 2 * Double.pi * phase
                    let triangle = 2 / Double.pi * asin(sin(angle))
                    let sineWeight = theme == .nativeGlass ? 0.72 : 0.55
                    wave = sineWeight * sin(angle) + (0.95 - sineWeight) * triangle
                        + 0.05 * sin(2 * angle)
                    decay = exp(-2.8 * progress)
                }
                let attack = min(1, time / 0.004)
                let release = min(1, Double(count - 1 - sample) / Double(rate) / 0.025)
                let value = Int16((wave * attack * release * decay * 0.42 * Double(Int16.max)).rounded())
                append(value, to: &pcm)
            }
            if index < melody.count - 1 {
                pcm.append(Data(repeating: 0, count: Int(note.gap * Double(rate)) * 2))
            }
        }

        var wav = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav) // PCM
        append(UInt16(1), to: &wav) // Mono
        append(UInt32(rate), to: &wav)
        append(UInt32(rate * 2), to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    /// Installs or refreshes the built-in pack. Every path component must be a real directory.
    public static func installBuiltInRetroPack(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> OpenPeonSoundPack {
        let home = try openHome(homeDirectory)
        defer { close(home) }
        let root = try openOrCreateDirectory(".openpeon", in: home)
        defer { close(root) }
        let packs = try openOrCreateDirectory("packs", in: root)
        defer { close(packs) }
        let directory = try openOrCreateDirectory("suyoi-retro-8bit", in: packs)
        defer { close(directory) }
        let sounds = try openOrCreateDirectory("sounds", in: directory)
        defer { close(sounds) }

        let entries: [(SuyoiAudioEvent, String, String)] = [
            (.sessionStarted, "session.start", "session-started.wav"),
            (.attentionRequired, "input.required", "attention-required.wav"),
            (.taskCompleted, "task.complete", "task-completed.wav"),
            (.taskError, "task.error", "task-error.wav"),
            (.quotaWarning, "resource.limit", "quota-warning.wav")
        ]
        // Reject unsafe existing destinations before replacing any pack files.
        try validateDestination("openpeon.json", in: directory)
        for (_, _, filename) in entries { try validateDestination(filename, in: sounds) }
        var categories: [String: Any] = [:]
        for (event, category, filename) in entries {
            try write(wavData(for: event, theme: .pixelArcade), named: filename, in: sounds)
            categories[category] = ["sounds": [["file": "sounds/\(filename)", "label": event.rawValue]]]
        }
        let manifest: [String: Any] = [
            "cesp_version": "1.0", "name": "suyoi-retro-8bit",
            "display_name": "Suyoi Retro 8-Bit (Built-in)", "version": "1.0.0",
            "author": ["name": "Suyoi"], "license": "MIT", "categories": categories
        ]
        try write(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
                  named: "openpeon.json", in: directory)
        let packDirectory = homeDirectory.appendingPathComponent(".openpeon/packs/suyoi-retro-8bit", isDirectory: true)
        guard let pack = ExperienceThemeCatalog.loadSoundPack(at: packDirectory),
              pack.eventSoundPaths.count == entries.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return pack
    }

    private struct Note {
        let midi: Int
        let duration: Double
        let gap: Double
    }

    private static func notes(for event: SuyoiAudioEvent) -> [Note] {
        switch event {
        case .sessionStarted:
            return [Note(midi: 72, duration: 0.105, gap: 0.025), Note(midi: 79, duration: 0.20, gap: 0)]
        case .attentionRequired:
            return [Note(midi: 81, duration: 0.10, gap: 0.045), Note(midi: 76, duration: 0.10, gap: 0.045),
                    Note(midi: 81, duration: 0.16, gap: 0)]
        case .taskCompleted:
            return [Note(midi: 72, duration: 0.10, gap: 0.018), Note(midi: 76, duration: 0.10, gap: 0.018),
                    Note(midi: 79, duration: 0.10, gap: 0.018), Note(midi: 84, duration: 0.26, gap: 0)]
        case .taskError:
            return [Note(midi: 63, duration: 0.20, gap: 0.018), Note(midi: 57, duration: 0.30, gap: 0)]
        case .quotaWarning:
            return [Note(midi: 77, duration: 0.13, gap: 0.12), Note(midi: 77, duration: 0.13, gap: 0)]
        }
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private static func openHome(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw CocoaError(.fileWriteInvalidFileName) }
        var normalizedPath = url.path
        for alias in ["/var/", "/tmp/", "/etc/"] where normalizedPath.hasPrefix(alias) {
            normalizedPath = "/private" + normalizedPath
            break
        }
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard !components.contains("..") else { throw CocoaError(.fileWriteInvalidFileName) }
        var directory = open("/", directoryFlags)
        guard directory >= 0 else { throw posixError() }
        for component in components {
            let next = openat(directory, component, directoryFlags)
            let failure = errno
            close(directory)
            guard next >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
            directory = next
        }
        return directory
    }

    private static func openOrCreateDirectory(_ name: String, in parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw posixError() }
        let directory = openat(parent, name, directoryFlags)
        guard directory >= 0 else { throw posixError() }
        return directory
    }

    private static func validateDestination(_ name: String, in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw posixError()
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Replace directory entries atomically; never open an existing destination for writing.
    private static func write(_ data: Data, named name: String, in directory: Int32) throws {
        try validateDestination(name, in: directory)
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let file = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        var installed = false
        defer {
            close(file)
            if !installed { unlinkat(directory, temporaryName, 0) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        try validateDestination(name, in: directory)
        guard renameat(directory, temporaryName, directory, name) == 0 else { throw posixError() }
        installed = true
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

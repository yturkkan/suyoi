import AppKit
import Darwin
import Foundation
import SuyoiCore

@MainActor
final class SoundEffectPlayer {
    private var activeSound: NSSound?

    func play(
        _ event: SuyoiAudioEvent,
        mode: SuyoiSoundMode,
        theme: SuyoiExperienceTheme,
        selectedPack: OpenPeonSoundPack?
    ) {
        guard mode != .muted else { return }

        if mode == .soundPack {
            if let pack = selectedPack,
               let relativeOrFullPath = pack.eventSoundPaths[event],
               let resolvedPath = Self.resolveValidatedAudioPath(relativeOrFullPath, inPackDirectory: pack.directoryPath),
               let sound = NSSound(contentsOfFile: resolvedPath, byReference: true) {
                activeSound = sound
                sound.play()
                return
            }

            let wavData = Self.synthesizedRetroWAV(for: event, theme: theme)
            if let sound = NSSound(data: wavData) {
                activeSound = sound
                sound.play()
                return
            }
        }

        if mode == .systemSounds && (theme == .pixelArcade || theme == .pixelOlive) {
            let wavData = Self.synthesizedRetroWAV(for: event, theme: theme)
            if let sound = NSSound(data: wavData) {
                activeSound = sound
                sound.play()
                return
            }
        }

        let soundName = ExperienceThemeCatalog.systemSoundName(for: event, theme: theme)
        if let sound = NSSound(named: NSSound.Name(soundName)) {
            activeSound = sound
            sound.play()
        }
    }

    static func synthesizedRetroWAV(
        for event: SuyoiAudioEvent,
        theme: SuyoiExperienceTheme
    ) -> Data {
        ChiptuneWaveformGenerator.wavData(for: event, theme: theme)
    }

    private static func resolveValidatedAudioPath(_ path: String, inPackDirectory directoryPath: String) -> String? {
        guard directoryPath.hasPrefix("/") else { return nil }
        let baseURL = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        let candidateURL: URL
        if path.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            candidateURL = baseURL.appendingPathComponent(path).standardizedFileURL
        }
        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard candidateURL.path.hasPrefix(basePrefix) else { return nil }
        var st = stat()
        guard lstat(candidateURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return candidateURL.path
    }
}

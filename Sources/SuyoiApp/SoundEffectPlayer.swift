import AppKit
import Darwin
import Foundation
import SuyoiCore

@MainActor
final class SoundEffectPlayer {
    func play(
        _ event: SuyoiAudioEvent,
        mode: SuyoiSoundMode,
        theme: SuyoiExperienceTheme,
        selectedPack: OpenPeonSoundPack?
    ) {
        guard mode != .muted else { return }

        if mode == .soundPack,
           let pack = selectedPack,
           let relativeOrFullPath = pack.eventSoundPaths[event],
           let resolvedPath = Self.resolveValidatedAudioPath(relativeOrFullPath, inPackDirectory: pack.directoryPath),
           let sound = NSSound(contentsOfFile: resolvedPath, byReference: true) {
            sound.play()
            return
        }

        let soundName = ExperienceThemeCatalog.systemSoundName(for: event, theme: theme)
        NSSound(named: NSSound.Name(soundName))?.play()
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

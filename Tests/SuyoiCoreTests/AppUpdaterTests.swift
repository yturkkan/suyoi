import Foundation
import Testing
@testable import SuyoiCore

@Suite("AppUpdater")
struct AppUpdaterTests {
    @Test("Streaming SHA-256 matches standard empty, short and multi-chunk vectors")
    func sha256KnownVectors() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-hash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let vectors: [(Data, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (Data(repeating: 97, count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        ]
        for (data, expected) in vectors {
            try data.write(to: file)
            #expect(try AppUpdater.computeSHA256Hex(of: file) == expected)
        }
    }

    @Test("Checksum parser accepts one digest with the canonical optional filename")
    func checksumParsing() {
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(AppUpdater.parseSHA256File(hash) == hash)
        #expect(AppUpdater.parseSHA256File(hash.uppercased() + "\n") == hash)
        #expect(AppUpdater.parseSHA256File(hash + "  Suyoi.app.zip\n") == hash)
        #expect(AppUpdater.parseSHA256File(hash + " *Suyoi.app.zip") == hash)
        for invalid in ["", String(hash.dropLast()), hash + "0", String(repeating: "g", count: 64),
                        hash + "  Other.app.zip", hash + "  Suyoi.app.zip\n" + hash,
                        hash + " Suyoi.app.zip", String(repeating: " ", count: 4097) + hash] {
            #expect(AppUpdater.parseSHA256File(invalid) == nil)
        }
    }

    @Test("Release parser discovers a checksum asset after the archive and rejects an untrusted URL")
    func checksumAssetDiscovery() throws {
        for trusted in [true, false] {
            let checksumURL = trusted
                ? "https://github.com/yturkkan/suyoi/releases/download/v0.1.9/Suyoi.app.zip.sha256"
                : "https://example.com/Suyoi.app.zip.sha256"
            let data = try JSONSerialization.data(withJSONObject: [
                "tag_name": "v0.1.9",
                "html_url": "https://github.com/yturkkan/suyoi/releases/tag/v0.1.9",
                "assets": [
                    ["name": "Suyoi.app.zip", "browser_download_url": "https://github.com/yturkkan/suyoi/releases/download/v0.1.9/Suyoi.app.zip", "size": 2048],
                    ["name": "Suyoi.app.zip.sha256", "browser_download_url": checksumURL, "size": 80]
                ]
            ])
            let result = try AppUpdater.parseReleaseResponse(data, currentVersion: "0.1.8")
            guard case .updateAvailable(let release) = result else {
                Issue.record("Expected a newer release")
                return
            }
            #expect(release.sha256AssetURL == (trusted ? URL(string: checksumURL) : nil))
            #expect(release.expectedSHA256 == nil)
        }
    }

    @Test("Staging rejects a SHA-256 mismatch before attempting archive extraction")
    func checksumMismatchBeforeExtraction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-stage-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("download.zip")
        // Intentionally not a zip: extraction would produce a different error.
        try Data(repeating: 0, count: 2048).write(to: archive)
        let downloadURL = URL(string: "https://github.com/yturkkan/suyoi/releases/download/v0.1.9/Suyoi.app.zip")!
        let updater = AppUpdater(downloadArchive: { request in
            #expect(request.url == downloadURL)
            return (archive, HTTPURLResponse(url: downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let release = AppReleaseInfo(
            version: "0.1.9", tagName: "v0.1.9",
            releaseURL: URL(string: "https://github.com/yturkkan/suyoi/releases/tag/v0.1.9")!,
            downloadURL: downloadURL, assetSizeBytes: 2048,
            expectedSHA256: String(repeating: "A", count: 64)
        )
        await #expect(throws: AppUpdaterError.bundleVerificationFailed("SHA-256 checksum mismatch")) {
            _ = try await updater.stageUpdate(release, currentBundleURL: directory.appendingPathComponent("Suyoi.app"))
        }
    }

    @Test("Staging requires a short bundle version matching the normalized release version")
    func shortBundleVersionVerification() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("suyoi-version-test-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let downloadURL = URL(string: "https://github.com/yturkkan/suyoi/releases/download/v1.2.3/Suyoi.app.zip")!
        let releaseURL = URL(string: "https://github.com/yturkkan/suyoi/releases/tag/v1.2.3")!
        let currentApp = root.appendingPathComponent("Suyoi.app")
        let versions: [Any?] = [nil, 123, "", "invalid", "1..2.3", "1.2.2", "1.2.3"]
        for (index, version) in versions.enumerated() {
            let fixture = root.appendingPathComponent(String(index))
            let app = fixture.appendingPathComponent("Suyoi.app")
            let contents = app.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/Suyoi")
            try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            var plist: [String: Any] = [
                "CFBundleIdentifier": "local.suyoi.app",
                "CFBundleExecutable": "Suyoi",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1.2.3"
            ]
            plist["CFBundleShortVersionString"] = version
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try #require(try runTool("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
            let archive = fixture.appendingPathComponent("archive.zip")
            try #require(try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path]) == 0)

            let release = AppReleaseInfo(
                version: "v1.2.3", tagName: "v1.2.3", releaseURL: releaseURL,
                downloadURL: downloadURL, assetSizeBytes: 2048,
                expectedSHA256: try AppUpdater.computeSHA256Hex(of: archive)
            )
            let updater = AppUpdater(downloadArchive: { _ in
                (archive, HTTPURLResponse(url: downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            if version as? String == "1.2.3" {
                let staged = try await updater.stageUpdate(release, currentBundleURL: currentApp)
                defer { try? fileManager.removeItem(at: staged.stagingDirectoryURL) }
                #expect(fileManager.fileExists(atPath: staged.verifiedAppBundleURL.path))
            } else {
                await #expect(throws: AppUpdaterError.bundleVerificationFailed("version mismatch"), "Fixture \(index)") {
                    let staged = try await updater.stageUpdate(release, currentBundleURL: currentApp)
                    try fileManager.removeItem(at: staged.stagingDirectoryURL)
                }
            }
        }
    }

    @Test("Installer replaces the bundle only after the process exits within the wait", arguments: [60, 61])
    func installerWaitsForExit(exitAfterSleeps: Int) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("suyoi-installer-test-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Suyoi.app")
        let staging = root.appendingPathComponent("staging")
        let update = staging.appendingPathComponent("Suyoi.app")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: update, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls")

        let mocks = #"""
        calls="$5"
        exit_after_sleeps="$6"
        sleeps=0
        kill() { [ "$sleeps" -lt "$exit_after_sleeps" ]; }
        fake_sleep() { sleeps=$((sleeps + 1)); printf 'wait\n' >> "$calls"; }
        fake_mv() { printf 'move\n' >> "$calls"; }
        fake_xattr() { printf 'xattr\n' >> "$calls"; }
        fake_open() { printf 'open\n' >> "$calls"; }
        fake_rm() { printf 'cleanup\n' >> "$calls"; }

        """#
        let script = mocks + AppUpdater.replacementScript
            .replacingOccurrences(of: "/bin/sleep", with: "fake_sleep")
            .replacingOccurrences(of: "/bin/mv", with: "fake_mv")
            .replacingOccurrences(of: "/usr/bin/xattr", with: "fake_xattr")
            .replacingOccurrences(of: "/usr/bin/open", with: "fake_open")
            .replacingOccurrences(of: "/bin/rm", with: "fake_rm")
        let result = try runTool("/bin/sh", [
            "-c", script, "fixture", "1", target.path, update.path, staging.path, calls.path, String(exitAfterSleeps)
        ])
        let processExited = exitAfterSleeps == 60
        #expect(result == (processExited ? 0 : 1))
        let expectedWait = String(repeating: "wait\n", count: 60)
        let expectedReplacement = processExited ? "move\nmove\nxattr\nopen\ncleanup\n" : ""
        #expect(try String(contentsOf: calls, encoding: .utf8) == expectedWait + expectedReplacement)
    }

    private func runTool(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("Version normalization strips leading v and pre-release suffix")
    func versionNormalization() {
        #expect(AppUpdater.normalizeVersion("v0.1.8") == "0.1.8")
        #expect(AppUpdater.normalizeVersion("V1.2.3") == "1.2.3")
        #expect(AppUpdater.normalizeVersion("0.1.8-rc1") == "0.1.8")
        #expect(AppUpdater.normalizeVersion("not-a-version") == "")
    }

    @Test("Semantic version comparison orders releases accurately")
    func versionComparison() {
        #expect(AppUpdater.isRemoteVersionNewer("v0.1.8", than: "0.1.7"))
        #expect(AppUpdater.isRemoteVersionNewer("0.2.0", than: "0.1.9"))
        #expect(!AppUpdater.isRemoteVersionNewer("0.1.8", than: "0.1.8"))
        #expect(!AppUpdater.isRemoteVersionNewer("0.1.7", than: "0.1.8"))
    }

    @Test("Pre-release identifiers follow SemVer 2.0 precedence")
    func prereleasePrecedence() {
        #expect(AppUpdater.isRemoteVersionNewer("v0.5.0-next.2", than: "0.5.0-next.1"))
        #expect(AppUpdater.isRemoteVersionNewer("0.5.0-next.10", than: "0.5.0-next.9"))
        #expect(AppUpdater.isRemoteVersionNewer("0.5.0", than: "0.5.0-next.9"))
        #expect(AppUpdater.isRemoteVersionNewer("0.5.1-next.1", than: "0.5.0"))
        #expect(!AppUpdater.isRemoteVersionNewer("0.5.0-next.1", than: "0.5.0-next.1"))
        #expect(!AppUpdater.isRemoteVersionNewer("0.4.1-next.2", than: "0.5.0-next.1"))
        #expect(!AppUpdater.isRemoteVersionNewer("0.5.0-next.1", than: "0.5.0"))
        #expect(SemanticVersion("0.5.0-alpha")! < SemanticVersion("0.5.0-alpha.1")!)
        #expect(SemanticVersion("0.5.0-1")! < SemanticVersion("0.5.0-alpha")!)
        #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
        #expect(SemanticVersion("1..2") == nil)
        #expect(SemanticVersion("1.2.3-") == nil)
        #expect(SemanticVersion("v0.5.0-next.2")?.description == "0.5.0-next.2")
    }

    @Test("Next channel picks the highest published -next pre-release from the release list")
    func nextChannelSelectsHighestPrerelease() throws {
        func release(_ tag: String, prerelease: Bool, draft: Bool = false) -> [String: Any] {
            [
                "tag_name": tag, "prerelease": prerelease, "draft": draft,
                "html_url": "https://github.com/yturkkan/suyoi/releases/tag/\(tag)",
                "assets": [
                    ["name": "Suyoi-Next.app.zip", "size": 4096,
                     "browser_download_url": "https://github.com/yturkkan/suyoi/releases/download/\(tag)/Suyoi-Next.app.zip"],
                    ["name": "Suyoi-Next.app.zip.sha256", "size": 90,
                     "browser_download_url": "https://github.com/yturkkan/suyoi/releases/download/\(tag)/Suyoi-Next.app.zip.sha256"]
                ]
            ]
        }
        let list: [[String: Any]] = [
            release("v0.3.6", prerelease: false),
            release("v0.5.0-next.3", prerelease: true, draft: true),
            release("v0.5.0-next.2", prerelease: true),
            release("v0.5.0-next.1", prerelease: true),
            release("v0.9.0", prerelease: true)
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        let result = try AppUpdater.parseReleaseResponse(data, currentVersion: "0.5.0-next.1", parallelNext: true)
        guard case .updateAvailable(let info) = result else {
            Issue.record("Expected next.2 to be offered")
            return
        }
        #expect(info.version == "0.5.0-next.2")
        #expect(info.tagName == "v0.5.0-next.2")
        #expect(info.sha256AssetURL?.absoluteString.hasSuffix("/v0.5.0-next.2/Suyoi-Next.app.zip.sha256") == true)

        let upToDate = try AppUpdater.parseReleaseResponse(data, currentVersion: "0.5.0-next.2", parallelNext: true)
        #expect(upToDate == .upToDate(currentVersion: "0.5.0-next.2"))
        let none = try AppUpdater.parseReleaseResponse(Data("[]".utf8), currentVersion: "0.5.0-next.2", parallelNext: true)
        #expect(none == .upToDate(currentVersion: "0.5.0-next.2"))
    }

    @Test("Staging refuses an archive that has no SHA-256 checksum")
    func stagingRequiresChecksum() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-nosha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("download.zip")
        try Data(repeating: 0, count: 2048).write(to: archive)
        let downloadURL = URL(string: "https://github.com/yturkkan/suyoi/releases/download/v0.1.9/Suyoi.app.zip")!
        let updater = AppUpdater(downloadArchive: { _ in
            (archive, HTTPURLResponse(url: downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let release = AppReleaseInfo(
            version: "0.1.9", tagName: "v0.1.9",
            releaseURL: URL(string: "https://github.com/yturkkan/suyoi/releases/tag/v0.1.9")!,
            downloadURL: downloadURL, assetSizeBytes: 2048
        )
        await #expect(throws: AppUpdaterError.bundleVerificationFailed("missing SHA-256 checksum")) {
            _ = try await updater.stageUpdate(release, currentBundleURL: directory.appendingPathComponent("Suyoi.app"))
        }
    }

    @Test("Release parser returns updateAvailable for newer valid GitHub release")
    func releaseParserUpdateAvailable() throws {
        let json = """
        {
          "tag_name": "v0.1.9",
          "html_url": "https://github.com/yturkkan/suyoi/releases/tag/v0.1.9",
          "assets": [
            {
              "name": "Suyoi.app.zip",
              "browser_download_url": "https://github.com/yturkkan/suyoi/releases/download/v0.1.9/Suyoi.app.zip",
              "size": 524288
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try AppUpdater.parseReleaseResponse(json, currentVersion: "0.1.8")
        #expect(
            result == .updateAvailable(
                AppReleaseInfo(
                    version: "0.1.9",
                    tagName: "v0.1.9",
                    releaseURL: URL(string: "https://github.com/yturkkan/suyoi/releases/tag/v0.1.9")!,
                    downloadURL: URL(string: "https://github.com/yturkkan/suyoi/releases/download/v0.1.9/Suyoi.app.zip")!,
                    assetSizeBytes: 524288
                )
            )
        )
    }

    @Test("Release parser returns upToDate when remote matches current version")
    func releaseParserUpToDate() throws {
        let json = """
        {
          "tag_name": "v0.1.8",
          "html_url": "https://github.com/yturkkan/suyoi/releases/tag/v0.1.8",
          "assets": []
        }
        """.data(using: .utf8)!

        let result = try AppUpdater.parseReleaseResponse(json, currentVersion: "0.1.8")
        #expect(result == .upToDate(currentVersion: "0.1.8"))
    }

    @Test("Release parser rejects download URLs outside the canonical repository")
    func releaseParserRejectsUntrustedDownloadHost() {
        let json = """
        {
          "tag_name": "v0.1.9",
          "html_url": "https://github.com/yturkkan/suyoi/releases/tag/v0.1.9",
          "assets": [
            {
              "name": "Suyoi.app.zip",
              "browser_download_url": "https://example.com/malicious/Suyoi.app.zip",
              "size": 524288
            }
          ]
        }
        """.data(using: .utf8)!

        #expect(throws: AppUpdaterError.noDownloadAsset) {
            _ = try AppUpdater.parseReleaseResponse(json, currentVersion: "0.1.8")
        }
    }
}

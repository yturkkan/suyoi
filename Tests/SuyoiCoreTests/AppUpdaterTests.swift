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

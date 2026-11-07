import Foundation
import Testing
@testable import SuyoiCore

@Suite("AppUpdater")
struct AppUpdaterTests {
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

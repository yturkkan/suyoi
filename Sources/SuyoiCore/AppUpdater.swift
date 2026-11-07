import Darwin
import Foundation

public struct AppReleaseInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let assetSizeBytes: Int64

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        downloadURL: URL,
        assetSizeBytes: Int64
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.assetSizeBytes = assetSizeBytes
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(AppReleaseInfo)
}

public struct StagedAppUpdate: Equatable, Sendable {
    public let release: AppReleaseInfo
    public let stagingDirectoryURL: URL
    public let verifiedAppBundleURL: URL
    public let targetAppBundleURL: URL

    public init(
        release: AppReleaseInfo,
        stagingDirectoryURL: URL,
        verifiedAppBundleURL: URL,
        targetAppBundleURL: URL
    ) {
        self.release = release
        self.stagingDirectoryURL = stagingDirectoryURL
        self.verifiedAppBundleURL = verifiedAppBundleURL
        self.targetAppBundleURL = targetAppBundleURL
    }
}

public enum AppUpdaterError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case rateLimited
    case noDownloadAsset
    case notRunningFromAppBundle
    case destinationNotWritable(String)
    case downloadFailed
    case extractionFailed
    case bundleVerificationFailed(String)
    case relaunchFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Could not read release metadata from GitHub."
        case .rateLimited:
            return "GitHub API rate limit reached. Please try again in a few minutes."
        case .noDownloadAsset:
            return "Latest release does not contain a verifiable Suyoi.app.zip package."
        case .notRunningFromAppBundle:
            return "Self-update requires running Suyoi from a .app bundle."
        case .destinationNotWritable(let path):
            return "Cannot write to \(path). Move Suyoi.app to a writable folder or /Applications."
        case .downloadFailed:
            return "Failed to download Suyoi.app.zip from GitHub Releases."
        case .extractionFailed:
            return "Failed to unpack the downloaded Suyoi.app archive."
        case .bundleVerificationFailed(let reason):
            return "Downloaded update failed verification (\(reason))."
        case .relaunchFailed:
            return "Failed to launch the update installer helper."
        }
    }
}

public protocol AppUpdating: Sendable {
    func checkForUpdates(currentVersion: String) async throws -> AppUpdateCheckResult
    func stageUpdate(_ release: AppReleaseInfo, currentBundleURL: URL) async throws -> StagedAppUpdate
    func launchReplacementAndRelaunch(_ staged: StagedAppUpdate, currentPID: Int32) throws
}

public struct AppUpdater: AppUpdating, Sendable {
    public static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/yturkkan/suyoi/releases/latest")!
    public static let allowedReleaseURLPrefix = "https://github.com/yturkkan/suyoi/releases/"
    public static let allowedDownloadURLPrefix = "https://github.com/yturkkan/suyoi/releases/download/"
    public static let expectedAssetName = "Suyoi.app.zip"
    public static let allowedBundleIdentifiers: Set<String> = ["local.suyoi.app", "io.suyoi.app"]
    public static let maxAssetBytes: Int64 = 100 * 1024 * 1024

    public init() {}

    public func checkForUpdates(currentVersion: String) async throws -> AppUpdateCheckResult {
        let session = Self.makeEphemeralSession(timeout: 12)
        var request = URLRequest(url: Self.latestReleaseEndpoint)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Suyoi-Updater", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppUpdaterError.invalidResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppUpdaterError.invalidResponse
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw AppUpdaterError.rateLimited
        }
        guard (200..<300).contains(http.statusCode), data.count <= 512 * 1024 else {
            throw AppUpdaterError.invalidResponse
        }

        return try Self.parseReleaseResponse(data, currentVersion: currentVersion)
    }

    public func stageUpdate(_ release: AppReleaseInfo, currentBundleURL: URL) async throws -> StagedAppUpdate {
        let standardizedBundleURL = currentBundleURL.standardizedFileURL
        guard standardizedBundleURL.pathExtension == "app" else {
            throw AppUpdaterError.notRunningFromAppBundle
        }
        guard release.downloadURL.absoluteString.hasPrefix(Self.allowedDownloadURLPrefix) else {
            throw AppUpdaterError.noDownloadAsset
        }

        let parentDirectoryURL = standardizedBundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDirectoryURL.path) else {
            throw AppUpdaterError.destinationNotWritable(parentDirectoryURL.path)
        }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suyoi-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            let zipURL = stagingDir.appendingPathComponent(Self.expectedAssetName, isDirectory: false)
            let session = Self.makeEphemeralSession(timeout: 60)
            var request = URLRequest(url: release.downloadURL)
            request.httpMethod = "GET"
            request.setValue("Suyoi-Updater", forHTTPHeaderField: "User-Agent")

            let (tempDownloadURL, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw AppUpdaterError.downloadFailed
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: tempDownloadURL.path)
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 1_024, fileSize <= Self.maxAssetBytes else {
                throw AppUpdaterError.downloadFailed
            }

            if FileManager.default.fileExists(atPath: zipURL.path) {
                try FileManager.default.removeItem(at: zipURL)
            }
            try FileManager.default.moveItem(at: tempDownloadURL, to: zipURL)

            let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let dittoStatus = try Self.runTool(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", zipURL.path, extractDir.path]
            )
            guard dittoStatus == 0 else {
                throw AppUpdaterError.extractionFailed
            }

            let extractedAppURL = extractDir.appendingPathComponent("Suyoi.app", isDirectory: true)
            try Self.verifyExtractedBundle(at: extractedAppURL, expectedVersion: release.version)

            return StagedAppUpdate(
                release: release,
                stagingDirectoryURL: stagingDir,
                verifiedAppBundleURL: extractedAppURL,
                targetAppBundleURL: standardizedBundleURL
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            if let updaterError = error as? AppUpdaterError {
                throw updaterError
            }
            throw AppUpdaterError.downloadFailed
        }
    }

    public func launchReplacementAndRelaunch(_ staged: StagedAppUpdate, currentPID: Int32) throws {
        // Fixed positional-argument shell script; never interpolates paths into script source.
        // $1 = PID to wait for
        // $2 = Target Suyoi.app destination path
        // $3 = Verified new Suyoi.app source path
        // $4 = Temporary staging directory path
        let script = """
        pid="$1"
        target_app="$2"
        new_app="$3"
        staging_dir="$4"
        backup_app="${staging_dir}/Suyoi-backup.app"

        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 60 ]; do
            /bin/sleep 0.1
            i=$((i + 1))
        done

        if [ -e "$target_app" ]; then
            /bin/mv "$target_app" "$backup_app" || exit 1
        fi

        if /bin/mv "$new_app" "$target_app"; then
            /usr/bin/xattr -dr com.apple.quarantine "$target_app" >/dev/null 2>&1 || true
            /bin/rm -rf "$staging_dir" >/dev/null 2>&1 || true
            /usr/bin/open "$target_app"
            exit 0
        else
            if [ -e "$backup_app" ] && [ ! -e "$target_app" ]; then
                /bin/mv "$backup_app" "$target_app" >/dev/null 2>&1 || true
            fi
            exit 1
        fi
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "suyoi-updater",
            String(currentPID),
            staged.targetAppBundleURL.path,
            staged.verifiedAppBundleURL.path,
            staged.stagingDirectoryURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppUpdaterError.relaunchFailed
        }
    }

    // MARK: - Pure Parsing & Version Comparison

    public static func parseReleaseResponse(_ data: Data, currentVersion: String) throws -> AppUpdateCheckResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTag = root["tag_name"] as? String,
              let rawReleaseURL = root["html_url"] as? String,
              rawReleaseURL.hasPrefix(allowedReleaseURLPrefix),
              let releaseURL = URL(string: rawReleaseURL) else {
            throw AppUpdaterError.invalidResponse
        }

        let normalizedRemote = normalizeVersion(rawTag)
        let normalizedCurrent = normalizeVersion(currentVersion)
        guard !normalizedRemote.isEmpty else {
            throw AppUpdaterError.invalidResponse
        }

        guard isRemoteVersionNewer(normalizedRemote, than: normalizedCurrent) else {
            return .upToDate(currentVersion: normalizedCurrent)
        }

        guard let assets = root["assets"] as? [[String: Any]] else {
            throw AppUpdaterError.noDownloadAsset
        }

        var matchedDownloadURL: URL?
        var matchedSize: Int64 = 0
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name == expectedAssetName,
                  let rawURL = asset["browser_download_url"] as? String,
                  rawURL.hasPrefix(allowedDownloadURLPrefix),
                  let url = URL(string: rawURL) else {
                continue
            }
            let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= maxAssetBytes else {
                continue
            }
            matchedDownloadURL = url
            matchedSize = size
            break
        }

        guard let downloadURL = matchedDownloadURL else {
            throw AppUpdaterError.noDownloadAsset
        }

        return .updateAvailable(
            AppReleaseInfo(
                version: normalizedRemote,
                tagName: rawTag,
                releaseURL: releaseURL,
                downloadURL: downloadURL,
                assetSizeBytes: matchedSize
            )
        )
    }

    public static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let dashIndex = trimmed.firstIndex(of: "-") {
            trimmed = String(trimmed[..<dashIndex])
        }
        let parts = trimmed.split(separator: ".")
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ Int($0) != nil }) else {
            return ""
        }
        return parts.joined(separator: ".")
    }

    public static func isRemoteVersionNewer(_ remote: String, than current: String) -> Bool {
        let remoteParts = normalizeVersion(remote).split(separator: ".").compactMap { Int($0) }
        let currentParts = normalizeVersion(current).split(separator: ".").compactMap { Int($0) }
        guard !remoteParts.isEmpty, !currentParts.isEmpty else {
            return false
        }
        let count = max(remoteParts.count, currentParts.count)
        for index in 0..<count {
            let r = index < remoteParts.count ? remoteParts[index] : 0
            let c = index < currentParts.count ? currentParts[index] : 0
            if r != c {
                return r > c
            }
        }
        return false
    }

    // MARK: - Verification Helpers

    private static func verifyExtractedBundle(at appURL: URL, expectedVersion: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw AppUpdaterError.bundleVerificationFailed("missing Suyoi.app")
        }

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              allowedBundleIdentifiers.contains(bundleID) else {
            throw AppUpdaterError.bundleVerificationFailed("bundle identifier mismatch")
        }

        if let bundleVersion = plist["CFBundleShortVersionString"] as? String,
           normalizeVersion(bundleVersion) != normalizeVersion(expectedVersion) {
            throw AppUpdaterError.bundleVerificationFailed("version mismatch")
        }

        _ = try? runTool(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", appURL.path]
        )

        let codesignStatus = try runTool(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
        guard codesignStatus == 0 else {
            throw AppUpdaterError.bundleVerificationFailed("invalid code signature")
        }
    }

    private static func runTool(executable: String, arguments: [String]) throws -> Int32 {
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

    private static func makeEphemeralSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }
}

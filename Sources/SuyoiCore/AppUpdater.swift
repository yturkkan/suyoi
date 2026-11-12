import CryptoKit
import Darwin
import Foundation

public struct AppReleaseInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let assetSizeBytes: Int64
    public let expectedSHA256: String?
    public let sha256AssetURL: URL?

    public init(
        version: String,
        tagName: String,
        releaseURL: URL,
        downloadURL: URL,
        assetSizeBytes: Int64,
        expectedSHA256: String? = nil,
        sha256AssetURL: URL? = nil
    ) {
        self.version = version
        self.tagName = tagName
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.assetSizeBytes = assetSizeBytes
        self.expectedSHA256 = expectedSHA256
        self.sha256AssetURL = sha256AssetURL
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
    public static let expectedChecksumAssetName = "Suyoi.app.zip.sha256"
    /// Next builds are published as pre-releases of the same repository; `/releases/latest`
    /// never returns pre-releases, so the Next channel lists releases and picks the highest
    /// `-next` pre-release itself.
    public static let nextReleasesListEndpoint = URL(string: "https://api.github.com/repos/yturkkan/suyoi/releases?per_page=30")!
    public static let nextAllowedReleaseURLPrefix = "https://github.com/yturkkan/suyoi/releases/"
    public static let nextAllowedDownloadURLPrefix = "https://github.com/yturkkan/suyoi/releases/download/"
    public static let nextExpectedAssetName = "Suyoi-Next.app.zip"
    public static let nextExpectedChecksumAssetName = "Suyoi-Next.app.zip.sha256"
    public static let nextTagMarker = "-next"
    public static let stableBundleIdentifiers: Set<String> = ["local.suyoi.app", "io.suyoi.app"]
    public static let nextBundleIdentifiers: Set<String> = ["local.suyoi.next"]
    public static let maxAssetBytes: Int64 = 100 * 1024 * 1024

    static func allowedBundleIdentifiers(parallelNext: Bool) -> Set<String> {
        parallelNext ? nextBundleIdentifiers : stableBundleIdentifiers
    }

    private static var activeReleaseEndpoint: URL {
        SuyoiAppIdentity.isParallelNextBuild ? nextReleasesListEndpoint : latestReleaseEndpoint
    }
    private static var activeReleaseURLPrefix: String {
        SuyoiAppIdentity.isParallelNextBuild ? nextAllowedReleaseURLPrefix : allowedReleaseURLPrefix
    }
    private static var activeDownloadURLPrefix: String {
        SuyoiAppIdentity.isParallelNextBuild ? nextAllowedDownloadURLPrefix : allowedDownloadURLPrefix
    }
    private static var activeAssetName: String {
        SuyoiAppIdentity.isParallelNextBuild ? nextExpectedAssetName : expectedAssetName
    }
    private static var activeChecksumAssetName: String {
        SuyoiAppIdentity.isParallelNextBuild ? nextExpectedChecksumAssetName : expectedChecksumAssetName
    }
    private static var activeExtractedAppName: String {
        SuyoiAppIdentity.isParallelNextBuild ? "Suyoi Next.app" : "Suyoi.app"
    }

    private let downloadArchive: (@Sendable (URLRequest) async throws -> (URL, URLResponse))?

    public init() { downloadArchive = nil }

    // Allows archive verification to be exercised without a live release request.
    init(downloadArchive: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)) {
        self.downloadArchive = downloadArchive
    }

    public func checkForUpdates(currentVersion: String) async throws -> AppUpdateCheckResult {
        let session = Self.makeEphemeralSession(timeout: 12)
        var request = URLRequest(url: Self.activeReleaseEndpoint)
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
        guard (200..<300).contains(http.statusCode), data.count <= 2 * 1024 * 1024 else {
            throw AppUpdaterError.invalidResponse
        }

        return try Self.parseReleaseResponse(data, currentVersion: currentVersion, parallelNext: SuyoiAppIdentity.isParallelNextBuild)
    }

    public func stageUpdate(_ release: AppReleaseInfo, currentBundleURL: URL) async throws -> StagedAppUpdate {
        let standardizedBundleURL = currentBundleURL.standardizedFileURL
        guard standardizedBundleURL.pathExtension == "app" else {
            throw AppUpdaterError.notRunningFromAppBundle
        }
        let isNext = SuyoiAppIdentity.isParallelNextBuild
        let downloadPrefix = isNext ? Self.nextAllowedDownloadURLPrefix : Self.allowedDownloadURLPrefix
        guard release.downloadURL.absoluteString.hasPrefix(downloadPrefix) else {
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
            let zipURL = stagingDir.appendingPathComponent(Self.activeAssetName, isDirectory: false)
            let session = Self.makeEphemeralSession(timeout: 60)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: release.downloadURL)
            request.httpMethod = "GET"
            request.setValue("Suyoi-Updater", forHTTPHeaderField: "User-Agent")

            let (tempDownloadURL, response): (URL, URLResponse)
            if let downloadArchive {
                (tempDownloadURL, response) = try await downloadArchive(request)
            } else {
                (tempDownloadURL, response) = try await session.download(for: request)
            }
            defer { try? FileManager.default.removeItem(at: tempDownloadURL) }
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

            let expectedHash: String?
            if let suppliedHash = release.expectedSHA256 {
                guard let hash = Self.parseSHA256File(suppliedHash, assetName: Self.activeAssetName) else {
                    throw AppUpdaterError.bundleVerificationFailed("invalid SHA-256 checksum")
                }
                expectedHash = hash
            } else if let checksumURL = release.sha256AssetURL {
                expectedHash = try await Self.fetchChecksum(at: checksumURL, downloadPrefix: downloadPrefix, assetName: Self.activeAssetName)
            } else {
                expectedHash = nil
            }
            if let expectedHash,
               try Self.computeSHA256Hex(of: zipURL).lowercased() != expectedHash.lowercased() {
                throw AppUpdaterError.bundleVerificationFailed("SHA-256 checksum mismatch")
            }

            let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let dittoStatus = try Self.runTool(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", zipURL.path, extractDir.path]
            )
            guard dittoStatus == 0 else {
                throw AppUpdaterError.extractionFailed
            }

            let extractedAppURL = extractDir.appendingPathComponent(Self.activeExtractedAppName, isDirectory: true)
            try Self.verifyExtractedBundle(at: extractedAppURL, expectedVersion: release.version, parallelNext: isNext)

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

    // Fixed positional-argument shell script; never interpolates paths into script source.
    // $1 = PID to wait for
    // $2 = Target Suyoi.app destination path
    // $3 = Verified new Suyoi.app source path
    // $4 = Temporary staging directory path
    static let replacementScript = """
        pid="$1"
        target_app="$2"
        new_app="$3"
        staging_dir="$4"
        backup_app="${staging_dir}/Suyoi-backup.app"

        i=0
        while [ "$i" -lt 60 ] && kill -0 "$pid" 2>/dev/null; do
            /bin/sleep 0.1
            i=$((i + 1))
        done

        if kill -0 "$pid" 2>/dev/null; then
            exit 1
        fi

        if [ -e "$target_app" ]; then
            /bin/mv "$target_app" "$backup_app" || exit 1
        fi

        if /bin/mv "$new_app" "$target_app"; then
            /usr/bin/xattr -dr com.apple.quarantine "$target_app" >/dev/null 2>&1 || true
            if /usr/bin/open "$target_app"; then
                /bin/rm -rf "$staging_dir" >/dev/null 2>&1 || true
                exit 0
            fi
        fi

        if [ -e "$backup_app" ]; then
            if [ -e "$target_app" ]; then
                /bin/mv "$target_app" "${staging_dir}/Suyoi-failed.app" || exit 1
            fi
            /bin/mv "$backup_app" "$target_app" || exit 1
            /bin/rm -rf "$staging_dir" >/dev/null 2>&1 || true
            /usr/bin/open "$target_app" >/dev/null 2>&1 || true
        fi
        exit 1
        """

    public func launchReplacementAndRelaunch(_ staged: StagedAppUpdate, currentPID: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.replacementScript,
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

    public static func parseReleaseResponse(_ data: Data, currentVersion: String, parallelNext: Bool = false) throws -> AppUpdateCheckResult {
        let releasePrefix = parallelNext ? nextAllowedReleaseURLPrefix : allowedReleaseURLPrefix
        let downloadPrefix = parallelNext ? nextAllowedDownloadURLPrefix : allowedDownloadURLPrefix
        let assetName = parallelNext ? nextExpectedAssetName : expectedAssetName
        let checksumAssetName = parallelNext ? nextExpectedChecksumAssetName : expectedChecksumAssetName

        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw AppUpdaterError.invalidResponse
        }
        let current = SemanticVersion(currentVersion)
        let currentDisplay = current?.description ?? normalizeVersion(currentVersion)

        let root: [String: Any]
        if parallelNext {
            let candidates: [[String: Any]]
            if let list = json as? [[String: Any]] {
                candidates = list
            } else if let single = json as? [String: Any] {
                candidates = [single]
            } else {
                throw AppUpdaterError.invalidResponse
            }
            // Only published Next pre-releases are eligible; drafts and stable tags are ignored.
            let eligible = candidates.compactMap { release -> (SemanticVersion, [String: Any])? in
                guard release["draft"] as? Bool != true,
                      release["prerelease"] as? Bool ?? true,
                      let tag = release["tag_name"] as? String, tag.contains(nextTagMarker),
                      let version = SemanticVersion(tag) else { return nil }
                return (version, release)
            }
            guard let best = eligible.max(by: { $0.0 < $1.0 }) else {
                return .upToDate(currentVersion: currentDisplay)
            }
            root = best.1
        } else {
            guard let single = json as? [String: Any] else { throw AppUpdaterError.invalidResponse }
            root = single
        }

        guard let rawTag = root["tag_name"] as? String,
              let rawReleaseURL = root["html_url"] as? String,
              rawReleaseURL.hasPrefix(releasePrefix),
              let releaseURL = URL(string: rawReleaseURL) else {
            throw AppUpdaterError.invalidResponse
        }

        guard let remote = SemanticVersion(rawTag) else {
            throw AppUpdaterError.invalidResponse
        }
        let normalizedRemote = remote.description

        guard let current, remote > current else {
            return .upToDate(currentVersion: currentDisplay)
        }

        guard let assets = root["assets"] as? [[String: Any]] else {
            throw AppUpdaterError.noDownloadAsset
        }

        var matchedDownloadURL: URL?
        var matchedChecksumURL: URL?
        var matchedSize: Int64 = 0
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let rawURL = asset["browser_download_url"] as? String,
                  rawURL.hasPrefix(downloadPrefix),
                  let url = URL(string: rawURL) else {
                continue
            }
            if name == checksumAssetName {
                matchedChecksumURL = url
                continue
            }
            guard name == assetName, matchedDownloadURL == nil else { continue }
            let size = (asset["size"] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= maxAssetBytes else {
                continue
            }
            matchedDownloadURL = url
            matchedSize = size
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
                assetSizeBytes: matchedSize,
                sha256AssetURL: matchedChecksumURL
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
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ Int($0) != nil }) else {
            return ""
        }
        return parts.joined(separator: ".")
    }

    public static func isRemoteVersionNewer(_ remote: String, than current: String) -> Bool {
        guard let remoteVersion = SemanticVersion(remote), let currentVersion = SemanticVersion(current) else {
            return false
        }
        return remoteVersion > currentVersion
    }

    // MARK: - Verification Helpers

    public static func computeSHA256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func parseSHA256File(_ text: String, assetName: String = expectedAssetName) -> String? {
        guard text.utf8.count <= 4096 else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = String(value.prefix(64))
        guard hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let suffix = value.dropFirst(64)
        guard suffix.isEmpty || suffix == "  \(assetName)" || suffix == " *\(assetName)" else {
            return nil
        }
        return hash.lowercased()
    }

    private static func fetchChecksum(
        at url: URL,
        downloadPrefix: String = allowedDownloadURLPrefix,
        assetName: String = expectedAssetName
    ) async throws -> String {
        guard url.absoluteString.hasPrefix(downloadPrefix) else {
            throw AppUpdaterError.bundleVerificationFailed("invalid SHA-256 checksum URL")
        }
        let session = makeEphemeralSession(timeout: 12)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue("Suyoi-Updater", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), response.expectedContentLength <= 4096 else {
                throw AppUpdaterError.bundleVerificationFailed("invalid SHA-256 checksum response")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4096 else {
                    throw AppUpdaterError.bundleVerificationFailed("invalid SHA-256 checksum response")
                }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8), let hash = parseSHA256File(text, assetName: assetName) else {
                throw AppUpdaterError.bundleVerificationFailed("invalid SHA-256 checksum")
            }
            return hash
        } catch {
            if let error = error as? AppUpdaterError { throw error }
            throw AppUpdaterError.bundleVerificationFailed("SHA-256 checksum download failed")
        }
    }

    private static func verifyExtractedBundle(at appURL: URL, expectedVersion: String, parallelNext: Bool) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw AppUpdaterError.bundleVerificationFailed("missing Suyoi.app")
        }

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              allowedBundleIdentifiers(parallelNext: parallelNext).contains(bundleID) else {
            throw AppUpdaterError.bundleVerificationFailed("bundle identifier mismatch")
        }

        guard let expected = SemanticVersion(expectedVersion),
              let bundleVersionString = plist["CFBundleShortVersionString"] as? String,
              let bundleVersion = SemanticVersion(bundleVersionString),
              bundleVersion == expected else {
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

/// Semantic version with SemVer 2.0 §11 precedence. Accepts an optional leading `v`,
/// 1–4 numeric core components (missing components compare as 0) and an optional
/// dot-separated pre-release (`0.5.0-next.2`). Build metadata (`+…`) is ignored.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let core: [Int]
    public let prerelease: [String]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var prereleaseText: Substring?
        if let dash = text.firstIndex(of: "-") {
            prereleaseText = text[text.index(after: dash)...]
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        var identifiers: [String] = []
        if let prereleaseText {
            let pieces = prereleaseText.split(separator: ".", omittingEmptySubsequences: false)
            for piece in pieces {
                guard !piece.isEmpty,
                      piece.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
                else { return nil }
                identifiers.append(String(piece))
            }
        }
        core = numbers
        prerelease = identifiers
    }

    public var description: String {
        let base = core.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    private func paddedCore(_ count: Int) -> [Int] {
        core + Array(repeating: 0, count: max(0, count - core.count))
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        return lhs.paddedCore(count) == rhs.paddedCore(count) && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        let left = lhs.paddedCore(count)
        let right = rhs.paddedCore(count)
        if left != right {
            for index in 0..<count where left[index] != right[index] {
                return left[index] < right[index]
            }
        }
        // A release ranks above any of its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        func numeric(_ identifier: String) -> Int? {
            identifier.utf8.allSatisfy({ (48...57).contains($0) }) ? Int(identifier) : nil
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (numeric(a), numeric(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

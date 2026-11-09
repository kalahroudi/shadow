// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Runs a command line tool. Real runs go through `Shell`; tests fake it.
public protocol CommandRunner: Sendable {
    func run(_ tool: String, _ args: [String]) async throws -> ShellResult
}

public struct ShellCommandRunner: CommandRunner {
    public init() {}
    public func run(_ tool: String, _ args: [String]) async throws -> ShellResult { try await Shell.run(tool, args, timeout: 60) }
}

/// Mounts and detaches a disk image (R9).
public protocol DiskImageMounter: Sendable {
    /// Mounts read-only and not browsable; returns the mount point.
    func attach(_ image: URL, at mountPoint: URL) async throws
    func detach(_ mountPoint: URL) async
}

public struct HdiutilMounter: DiskImageMounter {
    private let runner: any CommandRunner
    public init(runner: any CommandRunner = ShellCommandRunner()) { self.runner = runner }
    public func attach(_ image: URL, at mountPoint: URL) async throws {
        let r = try await runner.run("hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
        guard r.ok else { throw UpdateError(.verificationFailed, detail: "hdiutil attach exited \(r.status): \(r.stderr)") }
    }
    public func detach(_ mountPoint: URL) async {
        if let r = try? await runner.run("hdiutil", ["detach", mountPoint.path]), r.ok { return }
        _ = try? await runner.run("hdiutil", ["detach", "-force", mountPoint.path])
    }
}

/// Unpacks a zip into a folder (R9).
public protocol ArchiveExtractor: Sendable {
    func extract(_ archive: URL, into directory: URL) async throws
}

public struct DittoExtractor: ArchiveExtractor {
    private let runner: any CommandRunner
    public init(runner: any CommandRunner = ShellCommandRunner()) { self.runner = runner }
    public func extract(_ archive: URL, into directory: URL) async throws {
        let r = try await runner.run("ditto", ["-x", "-k", archive.path, directory.path])
        guard r.ok else { throw UpdateError(.verificationFailed, detail: "ditto exited \(r.status): \(r.stderr)") }
    }
}

/// Decides whether a staged bundle is safe to swap in (R9). Nothing is replaced unless every check passes.
public struct BundleVerifier: Sendable {
    private let runner: any CommandRunner
    public init(runner: any CommandRunner = ShellCommandRunner()) { self.runner = runner }

    public func verify(_ app: URL) async throws {
        func fail(_ why: String) -> UpdateError { UpdateError(.verificationFailed, detail: why) }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: app.path, isDirectory: &isDir), isDir.boolValue else { throw fail("staged bundle is missing") }
        let shadow = app.appendingPathComponent("Contents/MacOS/Shadow")
        let mcp = app.appendingPathComponent("Contents/MacOS/shadow-mcp")
        for exe in [shadow, mcp] where !fm.isExecutableFile(atPath: exe.path) { throw fail("\(exe.lastPathComponent) is missing or not executable") }

        let sign = try await run("codesign", ["--verify", "--deep", "--strict", app.path])
        guard sign.ok else { throw fail("codesign verification failed (\(sign.status))") }

        let test = try await run(shadow.path, ["--self-test"])
        guard test.ok else { throw fail("self-test exited \(test.status)") }
        let commit = (Bundle(url: app)?.infoDictionary?["ShadowCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let words = test.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "ok" else { throw fail("self-test did not print ok") }
        if let commit, words.dropFirst().first != commit { throw fail("self-test did not report the staged commit") }
    }

    private func run(_ tool: String, _ args: [String]) async throws -> ShellResult {
        do { return try await runner.run(tool, args) }
        catch { throw UpdateError(.verificationFailed, detail: "\(tool) could not run") }
    }
}

public enum InstallStep: String, Sendable { case downloading, checking, unpacking, verifying }

/// Download, check, unpack, stage and verify a release build (R7-R10). It never touches the installed app:
/// it only produces a verified bundle in the staging folder for the swap script to move into place.
public struct UpdateInstaller: Sendable {
    let transport: any UpdateTransport
    let paths: AppPaths
    let mounter: any DiskImageMounter
    let extractor: any ArchiveExtractor
    let verifier: BundleVerifier

    public init(transport: any UpdateTransport, paths: AppPaths, mounter: any DiskImageMounter = HdiutilMounter(),
                extractor: any ArchiveExtractor = DittoExtractor(), verifier: BundleVerifier = BundleVerifier()) {
        self.transport = transport; self.paths = paths; self.mounter = mounter; self.extractor = extractor; self.verifier = verifier
    }

    public var stagingDir: URL { paths.updatesDir.appendingPathComponent("staging", isDirectory: true) }
    public var stagedApp: URL { stagingDir.appendingPathComponent("Shadow.app", isDirectory: true) }

    /// The app must run from a `.app` whose parent folder the user can write to, or the swap would fail (R10).
    public static func preflight(bundleURL: URL) throws {
        let parent = bundleURL.deletingLastPathComponent()
        guard bundleURL.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError(.notWritable, detail: "install location is not writable")
        }
    }

    /// Returns the verified staged bundle. On any failure the download and staging files are removed.
    public func install(_ update: AvailableUpdate, installedBundle: URL, progress: @Sendable (InstallStep, Double) -> Void) async throws -> URL {
        try Self.preflight(bundleURL: installedBundle)
        let fm = FileManager.default
        try? fm.removeItem(at: paths.updatesDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        do {
            let staged = try await run(update, progress: progress)
            return staged
        } catch {
            try? fm.removeItem(at: paths.updatesDir)
            throw error
        }
    }

    private func run(_ update: AvailableUpdate, progress: @Sendable (InstallStep, Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let name = update.asset.url.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { throw UpdateError(.badRelease, detail: "unusable asset name") }
        let asset = paths.updatesDir.appendingPathComponent(name)
        let sums = paths.updatesDir.appendingPathComponent(UpdateCheck.checksumsName)

        progress(.downloading, 0)
        guard let sumsURL = update.checksums else { throw UpdateError(.checksumMismatch, detail: "release has no SHA256SUMS") }
        let sumsStatus = try await transport.download(sumsURL, to: sums) { _ in }
        guard sumsStatus == 200 else { throw UpdateError(.checksumMismatch, detail: "SHA256SUMS download returned HTTP \(sumsStatus)") }
        let status = try await transport.download(update.asset.url, to: asset) { progress(.downloading, $0) }
        guard status == 200 else { throw UpdateError(.badRelease, detail: "asset download returned HTTP \(status)") }

        progress(.checking, 0)
        try Self.verifyChecksum(of: asset, named: update.asset.name, sums: sums)

        progress(.unpacking, 0)
        try await unpack(asset)
        progress(.verifying, 0)
        try await verifier.verify(stagedApp)
        try? fm.removeItem(at: asset)
        progress(.verifying, 1)
        return stagedApp
    }

    /// Copies `Shadow.app` out of the image or archive into staging. The image is always detached.
    private func unpack(_ asset: URL) async throws {
        let fm = FileManager.default
        if asset.pathExtension.lowercased() == "dmg" {
            let mountPoint = paths.updatesDir.appendingPathComponent("mount", isDirectory: true)
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            do {
                try await mounter.attach(asset, at: mountPoint)
                try stage(from: mountPoint)
            } catch {
                await mounter.detach(mountPoint)
                throw error
            }
            await mounter.detach(mountPoint)
        } else {
            let out = paths.updatesDir.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try await extractor.extract(asset, into: out)
            try stage(from: out)
        }
    }

    private func stage(from folder: URL) throws {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first(where: { $0.lastPathComponent == "Shadow.app" }) ?? apps.first else {
            throw UpdateError(.verificationFailed, detail: "no app found in the download")
        }
        do { try fm.copyItem(at: app, to: stagedApp) }
        catch { throw UpdateError(.verificationFailed, detail: "could not copy the app to staging") }
    }

    // MARK: checksums (R8)

    /// Compares the file's SHA-256 with its line in `SHA256SUMS` (`<hex>  <name>`, hex in either case).
    static func verifyChecksum(of file: URL, named name: String, sums: URL) throws {
        let text = (try? String(contentsOf: sums, encoding: .utf8)) ?? ""
        guard let expected = expectedDigest(for: name, in: text) else { throw UpdateError(.checksumMismatch, detail: "no checksum entry for the asset") }
        guard try sha256(of: file) == expected else { throw UpdateError(.checksumMismatch, detail: "SHA-256 differs from SHA256SUMS") }
    }

    static func expectedDigest(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            if file == name, parts[0].count == 64 { return parts[0].lowercased() }
        }
        return nil
    }

    /// Streams the file through SHA-256 in 1 MiB chunks so big downloads are never held in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

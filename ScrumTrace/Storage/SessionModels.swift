import Darwin
import Foundation

@_silgen_name("fcopyfile")
private func scrumtraceFcopyfile(
    _ from: Int32,
    _ to: Int32,
    _ state: UnsafeMutableRawPointer?,
    _ flags: UInt32
) -> Int32

@_silgen_name("renameat")
private func scrumtraceRenameat(
    _ fromfd: Int32,
    _ from: UnsafePointer<CChar>?,
    _ tofd: Int32,
    _ to: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("unlinkat")
private func scrumtraceUnlinkat(
    _ fd: Int32,
    _ path: UnsafePointer<CChar>?,
    _ flag: Int32
) -> Int32

extension Notification.Name {
    static let scrumTraceCaptureGate = Notification.Name("ScrumTrace.captureGate")
    static let scrumTraceHUDSuppress = Notification.Name("ScrumTrace.hudSuppress")
    static let scrumTraceSessionEnding = Notification.Name("ScrumTrace.sessionEnding")
    static let scrumTraceCaptureFailed = Notification.Name("ScrumTrace.captureFailed")
}

/// Paths agents see are relative to `export/` (`shots/…`, `media/…`).
enum ExportRel {
    static func toExportRoot(_ path: String) -> String {
        guard let parts = normalizedComponents(path) else { return "" }
        if parts.first == "export" {
            return parts.dropFirst().joined(separator: "/")
        }
        return parts.joined(separator: "/")
    }

    /// Session-root path used for file I/O. Never rewrites `archive/` into `export/`.
    static func sessionPath(_ path: String) -> String {
        guard let parts = normalizedComponents(path) else { return "invalid" }
        if parts.first == "export" || parts.first == "archive" {
            return parts.joined(separator: "/")
        }
        return (["export"] + parts).joined(separator: "/")
    }

    static func isUnderExport(_ path: String) -> Bool {
        guard let parts = normalizedComponents(path) else { return false }
        return parts.first == "export" && parts.count >= 2 && parts[1] != "archive"
    }

    /// Paths agents and SESSION_BRIEF may link. Never `archive/`, never `..`.
    static func handoffPath(_ path: String) -> String? {
        let session = sessionPath(path)
        guard isUnderExport(session) else { return nil }
        let rel = toExportRoot(session)
        return rel.isEmpty ? nil : rel
    }

    /// Omitted-asset labels in `export/`. Strip `archive/` so the pack never names that folder.
    static func omittedHandoffPath(_ path: String) -> String {
        guard let parts = normalizedComponents(path) else { return "omitted" }
        var rest = parts
        if rest.first == "export" {
            rest = Array(rest.dropFirst())
        }
        if rest.first == "archive" {
            rest = Array(rest.dropFirst())
        }
        return rest.joined(separator: "/")
    }

    /// Collapse `.` / `..` and reject absolute paths that escape the session root.
    static func normalizedComponents(_ path: String) -> [String]? {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("./") {
            value = String(value.dropFirst(2))
        }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("://") {
            return nil
        }
        var stack: [String] = []
        for part in value.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return nil }
                stack.removeLast()
                continue
            }
            if part.contains("\\") { return nil }
            stack.append(String(part))
        }
        return stack.isEmpty ? nil : stack
    }

    static func isUnderSession(_ path: String) -> Bool {
        guard let parts = normalizedComponents(path), let first = parts.first else { return false }
        // Canonical SoT lives at the session root. Everything else is archive/ or export/.
        if parts.count == 1, first == ScrumTracePath.manifest {
            return true
        }
        return (first == "archive" || first == "export") && parts.count >= 2
    }

    /// Session folder itself must be a real directory. A planted session → /tmp
    /// link would otherwise make string-prefix containment succeed. A regular
    /// file at the session path is also refused. A missing path is allowed so
    /// `ensureRoot` can create the sessions folder. Prefer `O_NOFOLLOW` so
    /// `fileExists` cannot bless a directory symlink planted after the
    /// `isSymbolicLink` check.
    static func isUsableSessionRoot(_ sessionURL: URL) -> Bool {
        if (try? sessionURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        // `open(2)` follows intermediate parents. A planted `sessions` →
        // `/tmp` link would otherwise bless `sessions/<id>` as a real directory
        // inside the target. Only this parent name is checked so a user who
        // aliases `Movies/ScrumTrace` onto another volume still works, and so
        // `ensureRoot` can create `…/sessions` when that folder is still missing.
        let parent = sessionURL.deletingLastPathComponent()
        if parent.path != sessionURL.path,
           parent.lastPathComponent == "sessions",
           (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return false
        }
        let fd = sessionURL.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        if fd >= 0 {
            Darwin.close(fd)
            return true
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sessionURL.path, isDirectory: &isDir) {
            // Exists but O_NOFOLLOW directory open failed (symlink, file, or
            // unreadable dir). `isDir.boolValue` is true for a followed
            // symlink — still refuse.
            return isDir.boolValue && fd >= 0
        }
        return true
    }

    /// Normalized session-relative path that still lives under the session folder.
    /// Any symlink in the relative path (including a planted `archive/` or `shots/`
    /// directory link) is refused so later writes cannot follow into another tree.
    static func containedRelative(_ path: String, sessionURL: URL) -> String? {
        guard isUsableSessionRoot(sessionURL) else { return nil }
        guard isUnderSession(path), let parts = normalizedComponents(path) else { return nil }
        let joined = parts.joined(separator: "/")
        var current = sessionURL.standardizedFileURL
        for part in parts {
            let next = current.appendingPathComponent(part)
            if (try? next.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return nil
            }
            current = next
        }
        let stdRoot = sessionURL.standardizedFileURL
        let destPath = current.standardizedFileURL.path
        guard destPath == stdRoot.path || destPath.hasPrefix(stdRoot.path + "/") else { return nil }
        let root = sessionURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = current.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else { return nil }
        return joined
    }

    /// True when any path component under the session folder is a symbolic link.
    static func containsSymlinkComponent(_ relative: String, sessionURL: URL) -> Bool {
        if !isUsableSessionRoot(sessionURL) { return true }
        guard let parts = normalizedComponents(relative) else { return true }
        var current = sessionURL.standardizedFileURL
        for part in parts {
            let next = current.appendingPathComponent(part)
            if (try? next.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
            current = next
        }
        return false
    }

    static func existingSessionFile(_ path: String, sessionURL: URL) -> String? {
        guard let relative = containedRelative(path, sessionURL: sessionURL) else { return nil }
        let url = sessionURL.appendingPathComponent(relative)
        guard isContainedRegularFile(url, sessionRoot: sessionURL) else { return nil }
        return relative
    }

    /// Session-relative path from the URL's own components. Does not follow
    /// planted `archive/` or `shots/` directory links.
    static func unfollowedRelative(_ file: URL, sessionRoot: URL) -> String? {
        guard isUsableSessionRoot(sessionRoot) else { return nil }
        let root = sessionRoot.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath == root || filePath.hasPrefix(root + "/") else { return nil }
        let rest = String(filePath.dropFirst(root.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rest.isEmpty else { return nil }
        return normalizedComponents(rest)?.joined(separator: "/")
    }

    /// Readable only when every path component under the session folder is a
    /// real directory or file — not a symlink to `export/` or another tree.
    static func isReadableSessionFile(_ file: URL, sessionRoot: URL) -> Bool {
        guard let rel = unfollowedRelative(file, sessionRoot: sessionRoot) else { return false }
        return existingSessionFile(rel, sessionURL: sessionRoot) != nil
    }

    /// Regular file whose resolved target stays under `sessionRoot`. Symlinks are
    /// rejected so later reads cannot follow a link out of the session folder.
    /// A path that walks a planted `archive/` directory link is refused even when
    /// the resolved target is still inside the session (C2).
    static func isContainedRegularFile(_ file: URL, sessionRoot: URL) -> Bool {
        guard isUsableSessionRoot(sessionRoot) else { return false }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        let values = try? file.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { return false }
        guard values?.isRegularFile == true else { return false }
        guard let unfollowed = unfollowedRelative(file, sessionRoot: sessionRoot) else { return false }
        if containsSymlinkComponent(unfollowed, sessionURL: sessionRoot) { return false }
        return containedRelative(file, sessionRoot: sessionRoot) != nil
    }

    /// Resolved file relative to `root` when the target stays inside that folder.
    static func containedRelative(_ file: URL, sessionRoot: URL) -> String? {
        let root = sessionRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else { return nil }
        let rest = String(resolved.path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rest.isEmpty else { return nil }
        return normalizedComponents(rest)?.joined(separator: "/")
    }

    /// Zip member relative to `exportDir`. Rejects symlinks and files whose resolved
    /// path sits outside that folder so `/usr/bin/zip` cannot follow a link into
    /// `archive/` or another tree. Members are export-relative (`shots/001.jpg`);
    /// the folder need not be named `export/`.
    static func containedExportMember(file: URL, exportDir: URL) -> String? {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        let values = try? file.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { return nil }
        guard values?.isRegularFile == true else { return nil }
        guard let rel = containedRelative(file, sessionRoot: exportDir) else { return nil }
        let comps = rel.split(separator: "/").map(String.init)
        if comps.contains("archive") { return nil }
        return rel
    }

    /// Gate 6: AGENT_CONTEXT / SESSION_BRIEF may only link a file that exists
    /// under `export/` as a regular file after projection and omit.
    static func handoffFileIfPresent(_ path: String, sessionURL: URL) -> String? {
        guard let rel = handoffPath(path) else { return nil }
        guard existingSessionFile(sessionPath(rel), sessionURL: sessionURL) != nil else { return nil }
        return rel
    }

    /// Export-relative still/clip path safe for HTML `src`/`href` and markdown `![]()`.
    /// `javascript:` / `..` / `()` would break out of `img.src` or `![]()`.
    static func packMediaHandoff(_ path: String, sessionURL: URL) -> String? {
        guard let rel = handoffFileIfPresent(path, sessionURL: sessionURL) else { return nil }
        return packMediaRelative(rel)
    }

    static func packMediaRelative(_ rel: String) -> String? {
        guard let parts = normalizedComponents(rel), parts.count >= 2 else { return nil }
        guard parts[0] == "shots" || parts[0] == "media" else { return nil }
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        let joined = parts.joined(separator: "/")
        if joined.contains(":") || joined.contains("\\") { return nil }
        if joined.contains(where: { "()[]<>`".contains($0) }) { return nil }
        return joined
    }

    /// Write UTF-8 into `export/`. A planted symlink at the dest is deleted first
    /// so the write cannot follow into `archive/` or overwrite a sibling via a link.
    static func writeExportText(_ text: String, relative: String, sessionURL: URL) throws {
        let session = sessionPath(relative)
        guard isUnderExport(session) else {
            throw SessionVaultError.writeFailed(relative)
        }
        guard let data = text.data(using: .utf8) else {
            throw SessionVaultError.writeFailed(relative)
        }
        try writeContainedData(data, relative: session, sessionURL: sessionURL)
    }

    /// Create missing real directories and unlink a dest file-symlink so a
    /// subsequent write cannot follow `archive/` or `export/` into another tree.
    static func prepareContainedWrite(relative: String, sessionURL: URL) throws -> String {
        guard isUsableSessionRoot(sessionURL) else {
            throw SessionVaultError.writeFailed("session folder")
        }
        guard isUnderSession(relative), let parts = normalizedComponents(relative), !parts.isEmpty else {
            throw SessionVaultError.writeFailed(relative)
        }
        if parts.count == 1 {
            guard parts[0] == ScrumTracePath.manifest else {
                throw SessionVaultError.writeFailed(relative)
            }
        } else if parts.count < 2 {
            throw SessionVaultError.writeFailed(relative)
        }
        let joined = parts.joined(separator: "/")
        var current = sessionURL.standardizedFileURL
        for (index, part) in parts.enumerated() {
            let next = current.appendingPathComponent(part)
            let isLast = index == parts.count - 1
            let isLink = (try? next.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if isLast {
                if isLink {
                    try FileManager.default.removeItem(at: next)
                } else {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: next.path, isDirectory: &isDir), isDir.boolValue {
                        throw SessionVaultError.writeFailed(relative)
                    }
                }
            } else if isLink {
                throw SessionVaultError.writeFailed(relative)
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: next.path, isDirectory: &isDir) {
                    if !isDir.boolValue {
                        throw SessionVaultError.writeFailed(relative)
                    }
                } else {
                    try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
                }
                if (try? next.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    try? FileManager.default.removeItem(at: next)
                    throw SessionVaultError.writeFailed(relative)
                }
                let walked = parts[0...index].joined(separator: "/")
                if containsSymlinkComponent(walked, sessionURL: sessionURL) {
                    throw SessionVaultError.writeFailed(relative)
                }
            }
            current = next
        }
        guard let destRel = containedRelative(joined, sessionURL: sessionURL), destRel == joined else {
            throw SessionVaultError.writeFailed(relative)
        }
        return destRel
    }

    /// Write bytes under the session folder. A dest symlink is removed first so
    /// the write cannot follow out of `archive/` or `export/`. Intermediate
    /// directory symlinks are refused (a planted `archive/` → `export/` link
    /// must not receive Whisper JSON). Bytes land in an `O_EXCL` temp file,
    /// then `renameat` into a dest directory fd opened with `O_NOFOLLOW`. Do
    /// not use `Data.write(options: .atomic)` or `moveItem` — both follow a
    /// dest or temp symlink planted between prepare and write. A `.write-tmp`
    /// next to the dest would otherwise be enumerable into the zip allow-list.
    static func writeContainedData(_ data: Data, relative: String, sessionURL: URL) throws {
        let tmp: URL
        do {
            tmp = try writeExclusiveTemporaryFile(data, prefix: "scrumtrace-write")
        } catch {
            throw SessionVaultError.writeFailed(relative)
        }
        do {
            try fsyncRegularFile(tmp, relative: relative)
            try moveIntoSession(from: tmp, relative: relative, sessionURL: sessionURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// `O_EXCL` so a planted temp-path symlink cannot be followed. Caller deletes
    /// `tmp` if the later `moveIntoSession` fails.
    private static func writeExclusiveTemporaryFile(_ data: Data, prefix: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)"
        )
        let fd = tmp.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            throw SessionVaultError.writeFailed(prefix)
        }
        let ok: Bool
        if data.isEmpty {
            ok = Darwin.fsync(fd) == 0
        } else {
            ok = data.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                var offset = 0
                let size = buf.count
                while offset < size {
                    let n = Darwin.write(fd, base.advanced(by: offset), size - offset)
                    if n <= 0 { return false }
                    offset += Int(n)
                }
                return Darwin.fsync(fd) == 0
            }
        }
        Darwin.close(fd)
        guard ok else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionVaultError.writeFailed(prefix)
        }
        return tmp
    }

    /// `O_NOFOLLOW` + `fsync` so a planted temp symlink is refused and Whisper JSON
    /// is durable before `moveIntoSession`.
    private static func fsyncRegularFile(_ url: URL, relative: String) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed(relative)
        }
        let fd = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        let ok = Darwin.fsync(fd) == 0
        Darwin.close(fd)
        guard ok else {
            throw SessionVaultError.writeFailed(relative)
        }
    }

    /// Move a temp file onto a session-relative path. `renameat` into a dest
    /// directory fd opened with `O_NOFOLLOW` so a planted parent
    /// (`export/` → `archive/`) cannot steal the write. `unlinkat` replaces a
    /// dest file-symlink without following it into `archive/session.mp4`.
    static func moveIntoSession(from temp: URL, relative: String, sessionURL: URL) throws {
        if (try? temp.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed(relative)
        }
        let destRel = try prepareContainedWrite(relative: relative, sessionURL: sessionURL)
        guard let parts = normalizedComponents(destRel), let destName = parts.last, !destName.isEmpty else {
            throw SessionVaultError.writeFailed(relative)
        }
        let parentParts = Array(parts.dropLast())
        guard let destDirFd = openatDirectory(parts: parentParts, root: sessionURL) else {
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(destDirFd) }
        _ = destName.withCString { name in
            scrumtraceUnlinkat(destDirFd, name, 0)
        }
        let tmpName = temp.lastPathComponent
        let tmpParent = temp.deletingLastPathComponent()
        let srcDirFd = tmpParent.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard srcDirFd >= 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(srcDirFd) }
        let renamed = tmpName.withCString { fromName in
            destName.withCString { toName in
                scrumtraceRenameat(srcDirFd, fromName, destDirFd, toName)
            }
        }
        guard renamed == 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        let placedFd = destName.withCString { name in
            Darwin.openat(destDirFd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard placedFd >= 0 else {
            _ = destName.withCString { name in
                scrumtraceUnlinkat(destDirFd, name, 0)
            }
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(placedFd) }
        var placedInfo = stat()
        guard Darwin.fstat(placedFd, &placedInfo) == 0,
              (placedInfo.st_mode & S_IFMT) == S_IFREG else {
            _ = destName.withCString { name in
                scrumtraceUnlinkat(destDirFd, name, 0)
            }
            throw SessionVaultError.writeFailed(relative)
        }
        guard let visibleFd = openatFile(parts: parts, root: sessionURL) else {
            _ = destName.withCString { name in
                scrumtraceUnlinkat(destDirFd, name, 0)
            }
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(visibleFd) }
        var visibleInfo = stat()
        guard Darwin.fstat(visibleFd, &visibleInfo) == 0,
              placedInfo.st_dev == visibleInfo.st_dev,
              placedInfo.st_ino == visibleInfo.st_ino else {
            _ = destName.withCString { name in
                scrumtraceUnlinkat(destDirFd, name, 0)
            }
            throw SessionVaultError.writeFailed(relative)
        }
    }

    /// Working clips live under `archive/media-work/`. Export clips live under
    /// `export/media/`. Never overwrite `archive/session.mp4`.
    static func isAllowedClipDest(_ relative: String) -> Bool {
        guard let parts = normalizedComponents(relative), parts.count >= 3, parts.last == "clip.mp4" else {
            return false
        }
        if parts[0] == "archive", parts[1] == "media-work" {
            return true
        }
        if parts[0] == "export", parts[1] == "media" {
            return true
        }
        return false
    }

    static func parentIsSymbolicLink(_ file: URL) -> Bool {
        let parent = file.deletingLastPathComponent()
        return (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Deletes `file` only when it is a symbolic link (the link inode, not the
    /// target) or a regular file still inside `sessionRoot`. Used instead of
    /// `replaceItemAt` / unguarded `removeItem` so a planted dest cannot steer
    /// a write into `archive/` or a sibling tree.
    static func removeItemIfRegularFile(_ file: URL, sessionRoot: URL) throws {
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try FileManager.default.removeItem(at: file)
            return
        }
        guard isContainedRegularFile(file, sessionRoot: sessionRoot) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Read bytes without following a dest or intermediate symlink. `Data(contentsOf:)`
    /// and `NSImage(contentsOf:)` follow a link planted after `isReadableSessionFile`.
    static func readContainedData(relative: String, sessionURL: URL) -> Data? {
        guard isUsableSessionRoot(sessionURL) else { return nil }
        guard isUnderSession(relative), let parts = normalizedComponents(relative) else { return nil }
        guard let fd = openatFile(parts: parts, root: sessionURL) else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size >= 0, size <= 256 * 1024 * 1024 else { return nil }
        if size == 0 { return Data() }
        var data = Data(count: size)
        let filled = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            var offset = 0
            while offset < size {
                let n = Darwin.read(fd, base.advanced(by: offset), size - offset)
                if n <= 0 { return n == 0 ? offset : -1 }
                offset += Int(n)
            }
            return offset
        }
        guard filled == size else { return nil }
        return data
    }

    static func readContainedData(_ file: URL, sessionRoot: URL) -> Data? {
        guard let rel = unfollowedRelative(file, sessionRoot: sessionRoot) else { return nil }
        return readContainedData(relative: rel, sessionURL: sessionRoot)
    }

    /// Copy a contained session file to a unique temp URL using `fcopyfile` on an
    /// `O_NOFOLLOW` fd. Whisper / AVAsset still need a path, but it must not be a
    /// planted `archive/` link.
    static func copyContainedToTemporaryFile(
        relative: String,
        sessionURL: URL,
        prefix: String
    ) throws -> URL {
        guard isUsableSessionRoot(sessionURL) else {
            throw SessionVaultError.writeFailed(relative)
        }
        guard isUnderSession(relative), let parts = normalizedComponents(relative) else {
            throw SessionVaultError.writeFailed(relative)
        }
        var suffix = ""
        if let last = parts.last {
            let ext = URL(fileURLWithPath: last).pathExtension
            if !ext.isEmpty {
                suffix = ".\(ext)"
            }
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)\(suffix)"
        )
        if (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try FileManager.default.removeItem(at: dest)
        }
        let destFd = dest.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard destFd >= 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(destFd) }
        guard let srcFd = openatFile(parts: parts, root: sessionURL) else {
            try? FileManager.default.removeItem(at: dest)
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(srcFd) }
        // COPYFILE_DATA (1 << 3): copy file bytes only, no xattrs.
        if scrumtraceFcopyfile(srcFd, destFd, nil, 1 << 3) != 0 {
            try? FileManager.default.removeItem(at: dest)
            throw SessionVaultError.writeFailed(relative)
        }
        guard Darwin.fsync(destFd) == 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw SessionVaultError.writeFailed(relative)
        }
        return dest
    }

    /// Open a contained directory with `O_NOFOLLOW` on every component. Empty
    /// `parts` is the session root. Caller closes.
    private static func openatDirectory(parts: [String], root: URL) -> Int32? {
        let rootFd = root.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFd >= 0 else { return nil }
        if parts.isEmpty { return rootFd }
        var dirFd = rootFd
        for part in parts {
            let next = part.withCString { name in
                Darwin.openat(dirFd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            Darwin.close(dirFd)
            guard next >= 0 else { return nil }
            dirFd = next
        }
        return dirFd
    }

    /// Open a contained regular file with `O_NOFOLLOW` on every component. Caller closes.
    private static func openatFile(parts: [String], root: URL) -> Int32? {
        let rootFd = root.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFd >= 0 else { return nil }
        var dirFd = rootFd
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let flags: Int32 = isLast
                ? (O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                : (O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            let next = part.withCString { name in
                Darwin.openat(dirFd, name, flags)
            }
            Darwin.close(dirFd)
            guard next >= 0 else { return nil }
            if isLast {
                var info = stat()
                guard Darwin.fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                    Darwin.close(next)
                    return nil
                }
                return next
            }
            dirFd = next
        }
        Darwin.close(dirFd)
        return nil
    }

    /// Byte size of a contained regular file via `openat` + `fstat`.
    /// Following a dest symlink would let a planted
    /// `export/session-pack.zip` → `archive/session.mp4` make the
    /// 35 MB check weigh the master movie (C3).
    static func regularFileByteCount(relative: String, sessionURL: URL) -> Int? {
        guard isUsableSessionRoot(sessionURL) else { return nil }
        guard isUnderSession(relative), let parts = normalizedComponents(relative) else { return nil }
        guard let fd = openatFile(parts: parts, root: sessionURL) else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size >= 0 else { return nil }
        return size
    }

    static func regularFileByteCount(_ file: URL, sessionRoot: URL) -> Int? {
        guard let rel = unfollowedRelative(file, sessionRoot: sessionRoot) else { return nil }
        return regularFileByteCount(relative: rel, sessionURL: sessionRoot)
    }

    /// Temp-file size that refuses to follow a symlink (`O_NOFOLLOW`).
    static func unfollowedRegularFileByteCount(_ url: URL) -> Int? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        let fd = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size >= 0 else { return nil }
        return size
    }

    /// Read UTF-8 from a regular file without following a dest symlink.
    /// Bundle `String(contentsOf:)` follows a planted resource link.
    static func unfollowedUTF8Text(_ url: URL, maxBytes: Int = 2 * 1024 * 1024) -> String? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        let fd = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size >= 0, size <= maxBytes else { return nil }
        if size == 0 { return "" }
        var data = Data(count: size)
        let filled = data.withUnsafeMutableBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            var offset = 0
            while offset < size {
                let n = Darwin.read(fd, base.advanced(by: offset), size - offset)
                if n <= 0 { return n == 0 ? offset : -1 }
                offset += Int(n)
            }
            return offset
        }
        guard filled == size else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Open a directory without following a last-component symlink. Caller closes.
    static func openUnfollowedDirectory(_ url: URL) -> Int32? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return nil
        }
        let fd = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else { return nil }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    static func closeDescriptor(_ fd: Int32) {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// `renameat` a temp file into a directory already opened with `O_NOFOLLOW`.
    /// Nested parents are `mkdirat`/`openat` so a planted `shots/` link in the
    /// zip staging folder cannot steal pack members.
    static func placeIntoOpenedDirectory(from temp: URL, relative: String, directoryFd: Int32) throws {
        guard directoryFd >= 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        guard let parts = normalizedComponents(relative), let destName = parts.last, !destName.isEmpty else {
            throw SessionVaultError.writeFailed(relative)
        }
        if (try? temp.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SessionVaultError.writeFailed(relative)
        }
        var current = directoryFd
        var toClose: [Int32] = []
        defer {
            for fd in toClose.reversed() {
                Darwin.close(fd)
            }
        }
        for part in parts.dropLast() {
            let existing = part.withCString { name in
                Darwin.openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if existing >= 0 {
                if current != directoryFd {
                    toClose.append(current)
                }
                current = existing
                continue
            }
            let made = part.withCString { name in
                Darwin.mkdirat(current, name, 0o700)
            }
            if made != 0 {
                let err = Darwin.errno
                guard err == EEXIST else {
                    throw SessionVaultError.writeFailed(relative)
                }
            }
            let created = part.withCString { name in
                Darwin.openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard created >= 0 else {
                throw SessionVaultError.writeFailed(relative)
            }
            if current != directoryFd {
                toClose.append(current)
            }
            current = created
        }
        if current != directoryFd {
            toClose.append(current)
        }
        _ = destName.withCString { name in
            scrumtraceUnlinkat(current, name, 0)
        }
        let tmpName = temp.lastPathComponent
        let tmpParent = temp.deletingLastPathComponent()
        let srcDirFd = tmpParent.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return Darwin.open(ptr, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard srcDirFd >= 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(srcDirFd) }
        let renamed = tmpName.withCString { fromName in
            destName.withCString { toName in
                scrumtraceRenameat(srcDirFd, fromName, current, toName)
            }
        }
        guard renamed == 0 else {
            throw SessionVaultError.writeFailed(relative)
        }
        let placed = destName.withCString { name in
            Darwin.openat(current, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard placed >= 0 else {
            _ = destName.withCString { name in
                scrumtraceUnlinkat(current, name, 0)
            }
            throw SessionVaultError.writeFailed(relative)
        }
        defer { Darwin.close(placed) }
        var info = stat()
        guard Darwin.fstat(placed, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            _ = destName.withCString { name in
                scrumtraceUnlinkat(current, name, 0)
            }
            throw SessionVaultError.writeFailed(relative)
        }
    }

    /// Spawn `executable` with cwd bound to an already-opened directory fd.
    /// `Process.currentDirectoryURL` re-resolves the path at launch and would
    /// follow a planted `export/` → `archive/` link (C2).
    static func spawnWithDirectoryFd(
        executable: String,
        arguments: [String],
        directoryFd: Int32,
        stdin payload: Data
    ) throws {
        guard directoryFd >= 0 else {
            throw SessionVaultError.writeFailed("spawn")
        }
        var fds: [Int32] = [0, 0]
        let piped = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.pipe(base)
        }
        guard piped == 0 else {
            throw SessionVaultError.writeFailed("spawn")
        }
        let readFd = fds[0]
        let writeFd = fds[1]
        _ = Darwin.fcntl(readFd, F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(writeFd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            Darwin.close(readFd)
            Darwin.close(writeFd)
            throw SessionVaultError.writeFailed("spawn")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        guard posix_spawn_file_actions_addfchdir_np(&actions, directoryFd) == 0,
              posix_spawn_file_actions_adddup2(&actions, readFd, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, readFd) == 0,
              posix_spawn_file_actions_addclose(&actions, writeFd) == 0 else {
            Darwin.close(readFd)
            Darwin.close(writeFd)
            throw SessionVaultError.writeFailed("spawn")
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer {
            for ptr in argv {
                if let ptr { free(ptr) }
            }
        }
        var env: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        env.append(nil)
        defer {
            for ptr in env {
                if let ptr { free(ptr) }
            }
        }

        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { argvBuf -> Int32 in
            env.withUnsafeBufferPointer { envBuf -> Int32 in
                executable.withCString { path in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        nil,
                        argvBuf.baseAddress,
                        envBuf.baseAddress
                    )
                }
            }
        }
        Darwin.close(readFd)
        guard spawned == 0 else {
            Darwin.close(writeFd)
            throw SessionVaultError.writeFailed("spawn")
        }
        if !payload.isEmpty {
            _ = payload.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                var offset = 0
                let size = buf.count
                while offset < size {
                    let n = Darwin.write(writeFd, base.advanced(by: offset), size - offset)
                    if n <= 0 { return -1 }
                    offset += Int(n)
                }
                return offset
            }
        }
        Darwin.close(writeFd)
        var status: Int32 = 0
        let waited = Darwin.waitpid(pid, &status, 0)
        guard waited == pid, (status & 0o177) == 0, ((status >> 8) & 0xff) == 0 else {
            throw SessionVaultError.writeFailed("spawn")
        }
    }
}

enum MediaBudget {
    static let maxZipBytes = 35 * 1024 * 1024
    static let maxTasks = 8
    static let maxCandidateSlices = 12
    static let maxStills = 16
    static let clipWidth = 1280
    static let clipHeight = 720
    static let clipVideoBitrate = 1_200_000
    static let clipAudioBitrate = 96_000
    static let clipMinDuration: TimeInterval = 15
    static let clipMaxDuration: TimeInterval = 25
    static let clipMeanDuration: TimeInterval = 20
    static let stillMaxWidth = 1440
    static let stillJPEGQuality: CGFloat = 0.82
    static let keepConfidenceFloor = 0.55
    static let metadataSampleTimeoutMs: UInt64 = 200
    static let manifestVersion = "1.1.0"
}

enum CaptureSessionState: String, Codable, Sendable {
    case recording
    case paused

    var allowsNewCapture: Bool {
        switch self {
        case .recording:
            return true
        case .paused:
            return false
        }
    }
}

enum PipelineStatus: String, Codable, Sendable {
    case idle
    case recording
    case paused
    case transcribing
    case slicing
    case evaluating
    case synthesizing
    case completed
    case offlineFailed = "offline_failed"
}

enum SliceTrigger: String, Codable, Sendable {
    case shot
    case pin
    case keyword
}

enum SliceAnalysisStatus: String, Codable, Sendable {
    case pending
    case success
    case offlineFailed = "offline_failed"
    case skipped
}

enum TaskKind: String, Codable, Sendable {
    case bug
    case decision
    case actionItem = "action_item"
    case architectureNote = "architecture_note"
    case improvement
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskKind(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TaskStatus: String, Codable, Sendable {
    case confirmed
    case needsReview = "needs_review"
    case dropped

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskStatus(rawValue: raw) ?? .needsReview
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CandidateDecision: String, Codable, Sendable {
    case keep
    case needsReview = "needs_review"
    case drop

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CandidateDecision(rawValue: raw) ?? .needsReview
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ShotSource: String, Codable, Sendable {
    case voice
    case typed
    case mixed
}

enum SessionEventKind: String, Codable, Sendable {
    case start
    case stop
    case pause
    case resume
    case pin
    case shot
    case url
    case window
    case privacyPause = "privacy_pause"
    case error
}

struct DurationPair: Codable, Sendable, Hashable {
    var wallSeconds: TimeInterval
    var mediaSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case wallSeconds = "wall_seconds"
        case mediaSeconds = "media_seconds"
    }
}

struct PauseInterval: Codable, Sendable, Hashable {
    var pauseWall: TimeInterval
    var resumeWall: TimeInterval?
    var duration: TimeInterval

    enum CodingKeys: String, CodingKey {
        case pauseWall = "pause_wall"
        case resumeWall = "resume_wall"
        case duration
    }

    init(pauseWall: TimeInterval, resumeWall: TimeInterval?) {
        self.pauseWall = pauseWall
        self.resumeWall = resumeWall
        if let resumeWall {
            self.duration = max(0, resumeWall - pauseWall)
        } else {
            self.duration = 0
        }
    }

    mutating func close(at resumeWall: TimeInterval) {
        self.resumeWall = resumeWall
        self.duration = max(0, resumeWall - pauseWall)
    }
}

struct ProductContext: Codable, Sendable, Hashable {
    var appName: String
    var repoURL: String
    var techStack: String

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case repoURL = "repo_url"
        case techStack = "tech_stack"
    }

    static let empty = ProductContext(appName: "", repoURL: "", techStack: "")
}

struct ShotRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var tMedia: TimeInterval
    var rawPath: String
    var annotatedPath: String?
    var exportPath: String? = nil
    var note: String
    var source: ShotSource

    /// Annotated PNG exists only after Save. Unsaved Shots still have the raw frame.
    var stillCandidates: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in [annotatedPath, rawPath] {
            guard let path, !path.isEmpty, seen.insert(path).inserted else { continue }
            out.append(path)
        }
        return out
    }

    enum CodingKeys: String, CodingKey {
        case id
        case tMedia = "t_media"
        case rawPath = "raw_path"
        case annotatedPath = "annotated_path"
        case exportPath = "export_path"
        case note
        case source
    }
}

struct SliceRecord: Codable, Sendable, Identifiable, Hashable {
    var sliceId: String
    var startMedia: TimeInterval
    var endMedia: TimeInterval
    var trigger: SliceTrigger
    var associatedShotId: String?
    var clipPath: String?
    var exportClipPath: String? = nil
    var stills: [String]
    var analysisStatus: SliceAnalysisStatus
    var score: Double
    var mediaSent: [String]? = nil

    var id: String { sliceId }

    /// Drop clip/still paths that were never written (failed encode or still grab).
    func withExistingMedia(sessionURL: URL) -> SliceRecord {
        var copy = self
        if let clip = clipPath, ExportRel.existingSessionFile(clip, sessionURL: sessionURL) == nil {
            copy.clipPath = nil
        }
        copy.stills = stills.filter { ExportRel.existingSessionFile($0, sessionURL: sessionURL) != nil }
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case sliceId = "slice_id"
        case startMedia = "start_media"
        case endMedia = "end_media"
        case trigger
        case associatedShotId = "associated_shot_id"
        case clipPath = "clip_path"
        case exportClipPath = "export_clip_path"
        case stills
        case analysisStatus = "analysis_status"
        case score
        case mediaSent = "media_sent"
    }
}

struct QuoteRecord: Codable, Sendable, Hashable {
    var speaker: String
    var text: String
    var tMediaStart: TimeInterval
    var tMediaEnd: TimeInterval

    enum CodingKeys: String, CodingKey {
        case speaker
        case text
        case tMediaStart = "t_media_start"
        case tMediaEnd = "t_media_end"
    }
}

struct TaskRecord: Codable, Sendable, Identifiable, Hashable {
    var taskId: String
    var sourceSliceId: String
    var kind: TaskKind
    var status: TaskStatus
    var title: String
    var observed: String
    var stated: String
    var inferred: String
    var agentInstructions: String
    var quotes: [QuoteRecord]
    var evidenceMedia: [String]
    var confidence: Double

    var id: String { taskId }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case sourceSliceId = "source_slice_id"
        case kind
        case status
        case title
        case observed
        case stated
        case inferred
        case agentInstructions = "agent_instructions"
        case quotes
        case evidenceMedia = "evidence_media"
        case confidence
    }

    init(
        taskId: String,
        sourceSliceId: String,
        kind: TaskKind,
        status: TaskStatus,
        title: String,
        observed: String,
        stated: String,
        inferred: String,
        agentInstructions: String,
        quotes: [QuoteRecord],
        evidenceMedia: [String],
        confidence: Double
    ) {
        self.taskId = taskId
        self.sourceSliceId = sourceSliceId
        self.kind = kind
        self.status = status
        self.title = title
        self.observed = observed
        self.stated = stated
        self.inferred = inferred
        self.agentInstructions = agentInstructions
        self.quotes = quotes
        self.evidenceMedia = evidenceMedia
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(String.self, forKey: .taskId)
        sourceSliceId = try container.decode(String.self, forKey: .sourceSliceId)
        kind = try container.decode(TaskKind.self, forKey: .kind)
        status = try container.decode(TaskStatus.self, forKey: .status)
        title = try container.decode(String.self, forKey: .title)
        observed = try container.decodeIfPresent(String.self, forKey: .observed) ?? ""
        stated = try container.decodeIfPresent(String.self, forKey: .stated) ?? ""
        inferred = try container.decodeIfPresent(String.self, forKey: .inferred) ?? ""
        agentInstructions = try container.decodeIfPresent(String.self, forKey: .agentInstructions) ?? ""
        quotes = try container.decodeIfPresent([QuoteRecord].self, forKey: .quotes) ?? []
        evidenceMedia = try container.decodeIfPresent([String].self, forKey: .evidenceMedia) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
}

/// D7: when the pack can only keep `maxTasks`, human shots and `confirmed` win.
enum TaskRanking {
    static func selectForPack(_ tasks: [TaskRecord], limit: Int = MediaBudget.maxTasks) -> [TaskRecord] {
        let kept = tasks.filter { $0.status != .dropped }
        let sorted = kept.sorted(by: moreImportant)
        return Array(sorted.prefix(limit)).enumerated().map { index, task in
            var copy = task
            copy.taskId = String(format: "TASK-%02d", index + 1)
            return copy
        }
    }

    static func isShotBacked(_ task: TaskRecord) -> Bool {
        task.evidenceMedia.contains { path in
            path.lowercased().contains("shots/")
        }
    }

    static func moreImportant(lhs: TaskRecord, rhs: TaskRecord) -> Bool {
        let leftShot = isShotBacked(lhs)
        let rightShot = isShotBacked(rhs)
        if leftShot != rightShot { return leftShot }
        let leftRank = statusRank(lhs.status)
        let rightRank = statusRank(rhs.status)
        if leftRank != rightRank { return leftRank > rightRank }
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.taskId < rhs.taskId
    }

    private static func statusRank(_ status: TaskStatus) -> Int {
        switch status {
        case .confirmed: return 2
        case .needsReview: return 1
        case .dropped: return 0
        }
    }
}

struct CandidateRecord: Codable, Sendable, Hashable {
    var decision: CandidateDecision
    var confidence: Double
    var kind: TaskKind
    var title: String
    var observed: String
    var stated: String
    var inferred: String
    var agentInstructionsDraft: String
    var quotes: [QuoteRecord]
    var frameReferences: [String]

    enum CodingKeys: String, CodingKey {
        case decision
        case confidence
        case kind
        case title
        case observed
        case stated
        case inferred
        case agentInstructionsDraft = "agent_instructions_draft"
        case agentInstructions = "agent_instructions"
        case quotes
        case frameReferences = "frame_references"
    }

    init(
        decision: CandidateDecision,
        confidence: Double,
        kind: TaskKind,
        title: String,
        observed: String,
        stated: String,
        inferred: String,
        agentInstructionsDraft: String,
        quotes: [QuoteRecord],
        frameReferences: [String]
    ) {
        self.decision = decision
        self.confidence = confidence
        self.kind = kind
        self.title = title
        self.observed = observed
        self.stated = stated
        self.inferred = inferred
        self.agentInstructionsDraft = agentInstructionsDraft
        self.quotes = quotes
        self.frameReferences = frameReferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(CandidateDecision.self, forKey: .decision)
        confidence = try container.decode(Double.self, forKey: .confidence)
        kind = try container.decode(TaskKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        observed = try container.decodeIfPresent(String.self, forKey: .observed) ?? ""
        stated = try container.decodeIfPresent(String.self, forKey: .stated) ?? ""
        inferred = try container.decodeIfPresent(String.self, forKey: .inferred) ?? ""
        agentInstructionsDraft = try container.decodeIfPresent(String.self, forKey: .agentInstructionsDraft)
            ?? container.decodeIfPresent(String.self, forKey: .agentInstructions)
            ?? ""
        quotes = try container.decodeIfPresent([QuoteRecord].self, forKey: .quotes) ?? []
        frameReferences = try container.decodeIfPresent([String].self, forKey: .frameReferences) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(observed, forKey: .observed)
        try container.encode(stated, forKey: .stated)
        try container.encode(inferred, forKey: .inferred)
        try container.encode(agentInstructionsDraft, forKey: .agentInstructionsDraft)
        try container.encode(quotes, forKey: .quotes)
        try container.encode(frameReferences, forKey: .frameReferences)
    }
}

struct CandidateEvaluationResponse: Codable, Sendable {
    var candidates: [CandidateRecord]
}

struct SessionEvent: Codable, Sendable {
    var tWall: TimeInterval
    var tMedia: TimeInterval
    var kind: SessionEventKind
    var payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case tWall = "t_wall"
        case tMedia = "t_media"
        case kind
        case payload
    }
}

struct TranscriptWord: Codable, Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct TranscriptSegment: Codable, Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speaker: String?
    var words: [TranscriptWord]
}

struct FullTranscript: Codable, Sendable {
    var sessionId: String
    var language: String
    var segments: [TranscriptSegment]
    /// Hypotheses: `room` (microphone WAV) and/or `system` (movie audio).
    var sources: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case language
        case segments
        case sources
    }
}

/// What landed in `archive/audio.wav` vs `archive/session.mp4` audio.
struct CaptureAudioLayout: Codable, Sendable, Hashable {
    var microphoneWav: Bool
    var systemAudioInMovie: Bool

    enum CodingKeys: String, CodingKey {
        case microphoneWav = "microphone_wav"
        case systemAudioInMovie = "system_audio_in_movie"
    }

    static let both = CaptureAudioLayout(microphoneWav: true, systemAudioInMovie: true)

    static func load(sessionURL: URL) -> CaptureAudioLayout {
        guard ExportRel.existingSessionFile(ScrumTracePath.captureLayout, sessionURL: sessionURL) != nil else {
            return .both
        }
        guard let data = ExportRel.readContainedData(
            relative: ScrumTracePath.captureLayout,
            sessionURL: sessionURL
        ),
              let layout = try? JSONDecoder().decode(CaptureAudioLayout.self, from: data) else {
            return .both
        }
        return layout
    }

    func write(sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ExportRel.writeContainedData(
            try encoder.encode(self),
            relative: ScrumTracePath.captureLayout,
            sessionURL: sessionURL
        )
    }

    /// Room mic WAV is a different source from movie system audio. If WAV *is*
    /// system audio (no mic tap), transcribing the movie would duplicate it.
    func shouldTranscribeMovie(wavExists: Bool, movieExists: Bool) -> Bool {
        guard movieExists, systemAudioInMovie else { return false }
        if microphoneWav { return true }
        return !wavExists
    }
}

/// Gate 3 / Gate 6 measurements. Archive-only — never on the export allow-list.
struct PipelineTiming: Codable, Sendable, Hashable {
    var whisperWallSeconds: TimeInterval?
    var whisperSources: [String]
    var zipBytes: Int?
    var omittedCount: Int

    enum CodingKeys: String, CodingKey {
        case whisperWallSeconds = "whisper_wall_seconds"
        case whisperSources = "whisper_sources"
        case zipBytes = "zip_bytes"
        case omittedCount = "omitted_count"
    }

    init(
        whisperWallSeconds: TimeInterval? = nil,
        whisperSources: [String] = [],
        zipBytes: Int? = nil,
        omittedCount: Int = 0
    ) {
        self.whisperWallSeconds = whisperWallSeconds
        self.whisperSources = whisperSources
        self.zipBytes = zipBytes
        self.omittedCount = omittedCount
    }

    static func load(sessionURL: URL) -> PipelineTiming? {
        guard ExportRel.existingSessionFile(ScrumTracePath.pipelineTiming, sessionURL: sessionURL) != nil else {
            return nil
        }
        guard let data = ExportRel.readContainedData(
            relative: ScrumTracePath.pipelineTiming,
            sessionURL: sessionURL
        ) else { return nil }
        return try? JSONDecoder().decode(PipelineTiming.self, from: data)
    }

    func write(sessionURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ExportRel.writeContainedData(
            try encoder.encode(self),
            relative: ScrumTracePath.pipelineTiming,
            sessionURL: sessionURL
        )
    }
}

struct WindowMetadata: Sendable, Hashable {
    var appName: String
    var windowTitle: String
    var bundleIdentifier: String
    var url: String?
}

struct SessionManifest: Codable, Sendable {
    var manifestVersion: String
    var sessionId: String
    var createdAt: Date
    var pipelineStatus: PipelineStatus
    var duration: DurationPair
    var pauses: [PauseInterval]
    var productContext: ProductContext
    var shots: [ShotRecord]
    var slices: [SliceRecord]
    var tasks: [TaskRecord]
    var completedStages: [PipelineStatus]
    var includeFullTranscriptInZip: Bool
    var uploadConsent: UploadConsent
    var omitted: [OmittedAsset]

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case sessionId = "session_id"
        case createdAt = "created_at"
        case pipelineStatus = "pipeline_status"
        case duration
        case pauses
        case productContext = "product_context"
        case shots
        case slices
        case tasks
        case completedStages = "completed_stages"
        case includeFullTranscriptInZip = "include_full_transcript_in_zip"
        case uploadConsent = "upload_consent"
        case omitted
    }

    static func makeNew(sessionId: String, product: ProductContext) -> SessionManifest {
        SessionManifest(
            manifestVersion: MediaBudget.manifestVersion,
            sessionId: sessionId,
            createdAt: Date(),
            pipelineStatus: .idle,
            duration: DurationPair(wallSeconds: 0, mediaSeconds: 0),
            pauses: [],
            productContext: product,
            shots: [],
            slices: [],
            tasks: [],
            completedStages: [],
            includeFullTranscriptInZip: false,
            uploadConsent: .denied,
            omitted: []
        )
    }

    func hasCompleted(_ stage: PipelineStatus) -> Bool {
        completedStages.contains(stage)
    }

    mutating func markCompleted(_ stage: PipelineStatus) {
        if !completedStages.contains(stage) {
            completedStages.append(stage)
        }
    }
}

struct UploadConsent: Codable, Sendable, Hashable {
    var approved: Bool
    var approvedAt: Date?
    var provider: String
    var endpoint: String
    var model: String
    var includesClipAudio: Bool
    var includesStills: Bool

    enum CodingKeys: String, CodingKey {
        case approved
        case approvedAt = "approved_at"
        case provider
        case endpoint
        case model
        case includesClipAudio = "includes_clip_audio"
        case includesStills = "includes_stills"
    }

    static let denied = UploadConsent(
        approved: false,
        approvedAt: nil,
        provider: "",
        endpoint: "",
        model: "",
        includesClipAudio: false,
        includesStills: false
    )

    /// D15: Retry does not re-prompt unless this session never asked, the
    /// destination changed, or the payload kind (clip bytes vs stills-only) changed.
    /// `acceptsVideo` is the **actual** clip-upload capability (`willUploadClip`),
    /// not the settings flag alone.
    func needsReprompt(provider: String, endpoint: String, model: String, acceptsVideo: Bool) -> Bool {
        let neverAsked = self.provider.isEmpty && self.endpoint.isEmpty && self.model.isEmpty
        if neverAsked {
            return true
        }
        if self.provider != provider || self.endpoint != endpoint || self.model != model {
            return true
        }
        if includesClipAudio != acceptsVideo {
            return true
        }
        return false
    }
}

struct OmittedAsset: Codable, Sendable, Hashable {
    var path: String
    var reason: String
}

enum ScrumTracePath {
    static let archive = "archive"
    static let export = "export"
    static let shots = "archive/shots"
    static let exportShots = "export/shots"
    static let media = "export/media"
    static let mediaWork = "archive/media-work"
    static let manifest = "session.manifest.json"
    static let exportManifest = "export/session.manifest.json"
    static let agentContext = "export/AGENT_CONTEXT.md"
    static let sessionBrief = "export/SESSION_BRIEF.html"
    static let agentPrompt = "export/AGENT_PROMPT.txt"
    static let packZip = "export/session-pack.zip"
    static let omitted = "export/OMITTED.md"
    static let sessionMovie = "archive/session.mp4"
    static let audioWav = "archive/audio.wav"
    static let captureLayout = "archive/capture-layout.json"
    static let pipelineTiming = "archive/pipeline-timing.json"
    static let fullTranscript = "archive/full_transcript.json"
    static let events = "archive/events.jsonl"
}

enum PipelineStatusOrder {
    static let processingFlow: [PipelineStatus] = [
        .transcribing, .slicing, .evaluating, .synthesizing, .completed
    ]

    static func label(_ status: PipelineStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .transcribing: return "Transcribing"
        case .slicing: return "Slicing"
        case .evaluating: return "Evaluating"
        case .synthesizing: return "Synthesizing"
        case .completed: return "Completed"
        case .offlineFailed: return "Offline — needs review"
        }
    }
}

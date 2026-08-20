import Darwin
import Foundation

enum NoctCordSecureFileError: Error {
    case notFound
    case inaccessible
    case notRegular
    case tooLarge
    case changedDuringRead
    case unsafeDirectory
}

/// Descriptor-based file I/O for private state and untrusted user-selected
/// input. Final path components are never followed, byte counts are bounded,
/// and private replacements are written atomically inside a mode-0700 folder.
enum NoctCordSecureFileIO {
    static func validateBoundedRegularFile(
        at url: URL,
        maximumBytes: Int
    ) throws {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? NoctCordSecureFileError.notFound : .inaccessible
        }
        defer { _ = close(descriptor) }
        _ = try validateRegularDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            allowEmpty: false,
            requireCurrentUserOwner: false
        )
    }

    static func readBoundedRegularFile(
        at url: URL,
        maximumBytes: Int,
        allowEmpty: Bool = false,
        requireCurrentUserOwner: Bool = false
    ) throws -> Data {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? NoctCordSecureFileError.notFound : .inaccessible
        }
        defer { _ = close(descriptor) }

        let before = try validateRegularDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            allowEmpty: allowEmpty,
            requireCurrentUserOwner: requireCurrentUserOwner
        )
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))

        while true {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { throw NoctCordSecureFileError.tooLarge }
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(descriptor, base, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NoctCordSecureFileError.inaccessible }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maximumBytes else { throw NoctCordSecureFileError.tooLarge }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameFileAndVersion(before, after),
              data.count == Int(after.st_size),
              allowEmpty || !data.isEmpty else {
            throw NoctCordSecureFileError.changedDuringRead
        }
        return data
    }

    static func copyBoundedRegularFile(
        at sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: Int
    ) throws {
        let source: Int32 = sourceURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard source >= 0 else { throw NoctCordSecureFileError.inaccessible }
        defer { _ = close(source) }
        let before = try validateRegularDescriptor(
            source,
            maximumBytes: maximumBytes,
            allowEmpty: false,
            requireCurrentUserOwner: false
        )

        let destination: Int32 = destinationURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard destination >= 0 else { throw NoctCordSecureFileError.inaccessible }
        var destinationIsOpen = true
        var keepDestination = false
        defer {
            if destinationIsOpen { _ = close(destination) }
            if !keepDestination {
                destinationURL.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = unlink(path) }
                }
            }
        }
        guard fchmod(destination, mode_t(0o600)) == 0 else {
            throw NoctCordSecureFileError.inaccessible
        }

        var copied = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(source, base, raw.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NoctCordSecureFileError.inaccessible }
            if count == 0 { break }
            copied += count
            guard copied <= maximumBytes else { throw NoctCordSecureFileError.tooLarge }
            try writeAll(buffer, count: count, descriptor: destination)
        }

        var after = stat()
        guard fstat(source, &after) == 0,
              sameFileAndVersion(before, after),
              copied == Int(after.st_size),
              fsync(destination) == 0,
              close(destination) == 0 else {
            destinationIsOpen = false
            throw NoctCordSecureFileError.changedDuringRead
        }
        destinationIsOpen = false
        keepDestination = true
    }

    static func ensurePrivateDirectory(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw NoctCordSecureFileError.unsafeDirectory }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw NoctCordSecureFileError.unsafeDirectory
        }
    }

    static func writeAtomicPrivateFile(
        _ data: Data,
        to fileURL: URL,
        maximumBytes: Int
    ) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw NoctCordSecureFileError.tooLarge
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(at: directoryURL)
        let directory: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directory >= 0 else { throw NoctCordSecureFileError.unsafeDirectory }
        defer { _ = close(directory) }

        let name = fileURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw NoctCordSecureFileError.inaccessible
        }
        let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString { temporary in
            openat(
                directory,
                temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw NoctCordSecureFileError.inaccessible }
        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = close(descriptor) }
            if temporaryExists {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw NoctCordSecureFileError.inaccessible
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = write(descriptor, base.advanced(by: written), raw.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw NoctCordSecureFileError.inaccessible }
                written += result
            }
        }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw NoctCordSecureFileError.inaccessible
        }
        descriptorIsOpen = false
        let renameResult = temporaryName.withCString { temporary in
            name.withCString { destination in
                renameat(directory, temporary, directory, destination)
            }
        }
        guard renameResult == 0, fsync(directory) == 0 else {
            throw NoctCordSecureFileError.inaccessible
        }
        temporaryExists = false

        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        #endif
    }

    private static func validateRegularDescriptor(
        _ descriptor: Int32,
        maximumBytes: Int,
        allowEmpty: Bool,
        requireCurrentUserOwner: Bool
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size >= 0 else {
            throw NoctCordSecureFileError.notRegular
        }
        guard UInt64(status.st_size) <= UInt64(maximumBytes) else {
            throw NoctCordSecureFileError.tooLarge
        }
        guard allowEmpty || status.st_size > 0 else {
            throw NoctCordSecureFileError.notRegular
        }
        if requireCurrentUserOwner {
            guard status.st_uid == geteuid(),
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw NoctCordSecureFileError.notRegular
            }
        }
        return status
    }

    private static func sameFileAndVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func writeAll(
        _ buffer: [UInt8],
        count: Int,
        descriptor: Int32
    ) throws {
        try buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < count {
                let result = write(descriptor, base.advanced(by: written), count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw NoctCordSecureFileError.inaccessible }
                written += result
            }
        }
    }
}

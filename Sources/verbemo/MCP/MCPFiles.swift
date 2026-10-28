import Foundation
import Darwin

/// Only internal descriptor-relative operations accept filenames. Tool arguments never do.
enum MCPFiles {
    struct Stamp: Equatable {
        let isDirectory: Bool
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ stat: Darwin.stat) {
            isDirectory = (stat.st_mode & S_IFMT) == S_IFDIR
            device = stat.st_dev; inode = stat.st_ino; size = stat.st_size
            modifiedSeconds = stat.st_mtimespec.tv_sec; modifiedNanos = stat.st_mtimespec.tv_nsec
            changedSeconds = stat.st_ctimespec.tv_sec; changedNanos = stat.st_ctimespec.tv_nsec
        }
        var revision: String { "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanos):\(changedSeconds):\(changedNanos)" }
    }
    final class Directory {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
        deinit { close(fd) }
        static func root(_ root: URL) throws -> Directory {
            guard root.isFileURL, root.path.hasPrefix("/") else { throw MCPFailure(.dataUnreadable) }
            var current = Directory(fd: open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
            guard current.fd >= 0 else { throw MCPFailure(.dataUnreadable) }
            for part in MCPContract.normalizedRoot(root).path.split(separator: "/") {
                current = try current.directory(String(part))
            }
            return current
        }
        func directory(_ name: String) throws -> Directory {
            try Self.component(name)
            let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw MCPFailure(.dataUnreadable) }
            return Directory(fd: descriptor)
        }
        static func component(_ name: String) throws {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw MCPFailure(.dataUnreadable) }
        }
        func stamp() throws -> Stamp {
            var stat = Darwin.stat()
            guard fstat(fd, &stat) == 0 else { throw MCPFailure(.dataUnreadable) }
            return Stamp(stat)
        }
        func entryStamp(_ name: String) throws -> Stamp? {
            try Self.component(name)
            var stat = Darwin.stat()
            if fstatat(fd, name, &stat, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return nil }
                throw MCPFailure(.dataUnreadable)
            }
            guard (stat.st_mode & S_IFMT) == S_IFREG || (stat.st_mode & S_IFMT) == S_IFDIR else { throw MCPFailure(.dataUnreadable) }
            return Stamp(stat)
        }
        func entries(check: () throws -> Void = {}) throws -> [String] {
            // dup shares the directory offset; openat(".") creates a fresh description.
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard copy >= 0 else { throw MCPFailure(.dataUnreadable) }
            guard let directory = fdopendir(copy) else { close(copy); throw MCPFailure(.dataUnreadable) }
            defer { closedir(directory) }
            var result: [String] = []
            errno = 0
            while let entry = readdir(directory) {
                try check()
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
                }
                guard let name else { throw MCPFailure(.dataUnreadable) }
                if name != ".", name != ".." { result.append(name) }
                errno = 0
            }
            guard errno == 0 else { throw MCPFailure(.dataUnreadable) }
            return result.sorted()
        }
        func file(_ name: String) throws -> AudioHandle? {
            try Self.component(name)
            let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if descriptor < 0 {
                if errno == ENOENT { return nil }
                throw MCPFailure(.dataUnreadable)
            }
            var stat = Darwin.stat()
            guard fstat(descriptor, &stat) == 0, (stat.st_mode & S_IFMT) == S_IFREG else {
                close(descriptor); throw MCPFailure(.dataUnreadable)
            }
            return AudioHandle(fd: descriptor, stamp: Stamp(stat))
        }

    }
    /// A pinned file, independent of the meeting lock. Every chunk checks the opened revision.
    final class AudioHandle: @unchecked Sendable {
        private let fd: Int32
        let stamp: Stamp
        var size: Int64 { stamp.size }
        fileprivate init(fd: Int32, stamp: Stamp) { self.fd = fd; self.stamp = stamp }
        deinit { close(fd) }
        func validate() throws {
            var current = Darwin.stat()
            guard fstat(fd, &current) == 0 else { throw MCPFailure(.dataUnreadable) }
            guard Stamp(current) == stamp else { throw MCPFailure(.contentChanged) }
        }
        func read(offset: Int64, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, count <= 65536 else { throw MCPFailure(.invalidParams) }
            try validate()
            var bytes = [UInt8](repeating: 0, count: count)
            var amount: Int
            repeat { amount = pread(fd, &bytes, count, offset) } while amount < 0 && errno == EINTR
            guard amount >= 0 else { throw MCPFailure(.dataUnreadable) }
            try validate()
            return Data(bytes.prefix(amount))
        }
    }
}

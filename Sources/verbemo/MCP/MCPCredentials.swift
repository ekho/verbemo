import Foundation
import Security
import Darwin

struct MCPCredentials: Sendable {
    let home: Home
    var url: URL { home.keysDirectory.appendingPathComponent("mcp-token") }

    private func directory(create: Bool) throws -> Int32? {
        var fd = open(home.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MCPFailure(.dataUnreadable) }
        for name in [".config", "verbemo", "keys"] {
            if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST {
                close(fd); throw MCPFailure(.dataUnreadable)
            }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let missing = errno == ENOENT
            close(fd)
            guard next >= 0 else {
                if !create && missing { return nil }
                throw MCPFailure(.dataUnreadable)
            }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw MCPFailure(.dataUnreadable)
        }
        return fd
    }
    func read() throws -> String? {
        guard let dir = try directory(create: false) else { return nil }
        defer { close(dir) }
        let fd = openat(dir, "mcp-token", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw MCPFailure(.dataUnreadable)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size == 64 else { throw MCPFailure(.dataUnreadable) }
        var bytes = [UInt8](repeating: 0, count: 65)
        guard Darwin.read(fd, &bytes, 65) == 64 else { throw MCPFailure(.dataUnreadable) }
        let token = String(decoding: bytes.prefix(64), as: UTF8.self)
        guard token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MCPFailure(.dataUnreadable) }
        return token
    }
    /// Only explicit local enable/rotate calls this method.
    func rotate() throws -> String {
        guard let dir = try directory(create: true) else { throw MCPFailure(.dataUnreadable) }
        defer { close(dir) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPFailure(.dataUnreadable) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let temp = ".mcp-" + UUID().uuidString
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MCPFailure(.dataUnreadable) }
        defer { close(fd); unlinkat(dir, temp, 0) }
        let data = Data(token.utf8)
        guard data.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == 64,
              fsync(fd) == 0, renameat(dir, temp, dir, "mcp-token") == 0,
              fsync(dir) == 0, try read() == token else { throw MCPFailure(.dataUnreadable) }
        return token
    }
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == 64, b.count == 64 else { return false }
        var difference: UInt8 = 0
        for i in 0..<64 { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

struct MCPConfiguration: Sendable, Equatable {
    let raw: [String: MCPJSON]
    let enabled: Bool
    let port: Int
    static func read(home: Home) throws -> Self {
        let fd = open(home.configFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let raw: [String: MCPJSON]
        if fd < 0 {
            guard errno == ENOENT else { throw MCPFailure(.dataUnreadable) }
            raw = [:]
        } else {
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MCPFailure(.dataUnreadable) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw = [:] }
            else {
                guard let object = try MCPJSON.parse(data).object else { throw MCPFailure(.dataUnreadable) }
                raw = object
            }
        }
        if let section = raw["mcp"], section.object == nil { throw MCPFailure(.invalidParams) }
        let mcp = raw["mcp"]?.object ?? [:]
        guard mcp["enabled"] == nil || mcp["enabled"]?.bool != nil else { throw MCPFailure(.invalidParams) }
        let port: Int
        if let value = mcp["port"] {
            guard case .int(let number) = value, (1024...65535).contains(number) else { throw MCPFailure(.invalidParams) }
            port = number
        } else { port = 52763 }
        return Self(raw: raw, enabled: mcp["enabled"]?.bool ?? false, port: port)
    }
}

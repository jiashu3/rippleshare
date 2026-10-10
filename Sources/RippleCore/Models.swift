import Foundation

public struct Server: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String
    public var startPath: String
    public init(id: UUID = UUID(), name: String = "", host: String = "", port: Int = 22,
                username: String = "", identityFile: String = "", startPath: String = "") {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.username = username; self.identityFile = identityFile; self.startPath = startPath
    }
    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              (1...65535).contains(port) else { throw RippleError("请输入有效的主机名 / IP 和端口。") }
        let users = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !username.isEmpty, !username.hasPrefix("-"), username.unicodeScalars.allSatisfy(users.contains)
        else { throw RippleError("请输入有效的 SSH 用户名。") }
        if !startPath.isEmpty { try Paths.validateAbsolute(startPath) }
        if !identityFile.isEmpty { try Paths.validateAbsolute(identityFile) }
    }
    public var destination: String { username + "@" + host }
    public var rsyncDestination: String { username + "@" + (host.contains(":") ? "[\(host)]" : host) }
}

public struct FileEntry: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modified: Double
    public var id: String { path }
    public init(name: String, path: String, isDirectory: Bool, isSymlink: Bool, size: Int64, modified: Double) {
        self.name = name; self.path = path; self.isDirectory = isDirectory
        self.isSymlink = isSymlink; self.size = size; self.modified = modified
    }
    public static func local(_ path: String) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                   includingPropertiesForKeys: Array(keys)).map { url in
            let v = try url.resourceValues(forKeys: keys)
            return FileEntry(name: url.lastPathComponent, path: url.path,
                             isDirectory: v.isDirectory == true && v.isSymbolicLink != true,
                             isSymlink: v.isSymbolicLink == true, size: Int64(v.fileSize ?? 0),
                             modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
    }
}

public enum Direction: String, Codable, Sendable { case upload, download }
public enum TransferState: String, Codable, Sendable {
    case queued, preparing, transferring, verifying, completed, paused, failed
    public var isActive: Bool { [.preparing, .transferring, .verifying].contains(self) }
    public var label: String {
        switch self {
        case .queued: return "等待中"
        case .preparing: return "检查文件与空间"
        case .transferring: return "正在传输"
        case .verifying: return "校验文件内容"
        case .completed: return "已完成"
        case .paused: return "已暂停"
        case .failed: return "需要处理"
        }
    }
}
public struct TransferJob: Codable, Identifiable, Sendable {
    public var id: UUID
    public var server: Server
    public var direction: Direction
    public var source: String
    public var destinationDirectory: String
    public var state: TransferState = .queued
    public var detail: String = ""
    public var created: Date = Date()
    public var name: String { (source as NSString).lastPathComponent }
    public var stage: String { Paths.join(destinationDirectory, ".rippleshare-" + id.uuidString.lowercased()) }
    public var payload: String { Paths.join(stage, "payload") }
    public var finalPath: String { Paths.join(destinationDirectory, name) }
    public init(id: UUID = UUID(), server: Server, direction: Direction, source: String, destinationDirectory: String) {
        self.id = id; self.server = server; self.direction = direction
        self.source = source; self.destinationDirectory = destinationDirectory
    }
}

public struct RippleError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Paths {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func join(_ parent: String, _ child: String) -> String {
        (parent == "/" ? "" : parent) + "/" + child
    }
    public static func validateAbsolute(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0") else { throw RippleError("必须使用绝对路径。") }
    }
    public static func validateLeaf(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0")
        else { throw RippleError("请输入有效的文件名。") }
    }
    public static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
}

public final class StateStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RippleShare", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    public func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let url = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func save<T: Encodable>(_ value: T, as name: String) throws {
        let data = try JSONEncoder().encode(value)
        let url = directory.appendingPathComponent(name + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

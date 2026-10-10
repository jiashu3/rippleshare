import Foundation

public struct RemoteListing: Decodable, Sendable { public let path: String; public let entries: [FileEntry] }
public struct Capabilities: Decodable, Sendable { public let home: String; public let rsync: String; public let python: String }
public struct Inspection: Decodable, Sendable { public let count: Int; public let bytes: Int64 }
private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let value: T?; let error: String? }
public struct EmptyReply: Decodable, Sendable {}

public struct SSHClient: Sendable {
    public let server: Server
    public init(server: Server) { self.server = server }
    public func arguments() throws -> [String] {
        try server.validate()
        var args = ["-T", "-p", String(server.port), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                    "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
                    "-o", "ControlPath=none"]
        if !server.identityFile.isEmpty { args += ["-i", server.identityFile, "-o", "IdentitiesOnly=yes"] }
        return args
    }
    public func request<T: Decodable & Sendable>(_ request: [String: String], as type: T.Type,
                                               timeout: Double? = 60) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let script = try String(contentsOf: Bundle.module.url(forResource: "remote", withExtension: "py")!, encoding: .utf8)
        let command = "python3 -c " + Paths.quote(script) + " " + Paths.quote(data.base64EncodedString())
        let result = try await ProcessRunner.run("/usr/bin/ssh", try arguments() + [server.destination, command], timeout: timeout)
        if let reply = try? JSONDecoder().decode(Envelope<T>.self, from: Data(result.output.utf8)) {
            guard reply.ok, let value = reply.value else { throw RippleError(reply.error ?? "服务器操作失败。") }
            return value
        }
        _ = try result.checked()
        throw RippleError("服务器返回了无法识别的数据。请确认已安装 Python 3，且 SSH 启动脚本不向 stdout 输出文字。")
    }
    public func probe() async throws -> Capabilities { try await request(["op": "probe"], as: Capabilities.self) }
    public func list(_ path: String) async throws -> RemoteListing {
        try Paths.validateAbsolute(path)
        return try await request(["op": "list", "path": path], as: RemoteListing.self)
    }
    public func mkdir(parent: String, name: String) async throws {
        try Paths.validateLeaf(name)
        let _: EmptyReply = try await request(["op": "mkdir", "parent": parent, "name": name], as: EmptyReply.self)
    }
    public func rename(path: String, name: String) async throws {
        try Paths.validateLeaf(name)
        let _: EmptyReply = try await request(["op": "rename", "path": path, "name": name], as: EmptyReply.self)
    }
    public var terminalSetupCommand: String {
        var words = ["ssh", "-p", String(server.port)]
        if !server.identityFile.isEmpty { words += ["-i", server.identityFile] }
        words += [server.destination]
        return words.map(Paths.quote).joined(separator: " ")
    }
}

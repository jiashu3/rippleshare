import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct TransferUpdate: Sendable {
    public let state: TransferState
    public let detail: String
    public init(_ state: TransferState, _ detail: String) { self.state = state; self.detail = detail }
}

public enum TransferEngine {
    public static func findRsync() async throws -> String {
        for path in ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"] {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let result = try await ProcessRunner.run(path, ["--version"], timeout: 10)
            if result.status == 0 && result.output.range(of: #"version\s+[3-9]\."#, options: .regularExpression) != nil { return path }
        }
        throw RippleError("需要 rsync 3 或更新版本。请在 Mac 终端运行 brew install rsync，然后重试。")
    }
    public static func arguments(for job: TransferJob, verify: Bool, ssh: SSHClient) throws -> [String] {
        try job.server.validate()
        try Paths.validateAbsolute(job.source)
        try Paths.validateAbsolute(job.destinationDirectory)
        try Paths.validateLeaf(job.name)
        // Modern rsync sends paths inside its protocol, not through a remote shell.
        let transport = (["/usr/bin/ssh"] + (try ssh.arguments())).map(Paths.quote).joined(separator: " ")
        var args = ["--recursive", "--links", "--times", "--perms", "--checksum", "--protect-args",
                    "--timeout=60", "--rsh=" + transport]
        if verify { args += ["--dry-run", "--delete", "--itemize-changes", "--out-format=%i %n%L"] }
        else { args += ["--partial", "--partial-dir=.rippleshare-partial-" + job.id.uuidString.lowercased(),
                        "--delete-delay", "--info=progress2", "--no-inc-recursive"] }
        let remote = job.server.rsyncDestination + ":"
        let source = job.direction == .upload ? job.source : remote + job.source
        let target = job.direction == .upload ? remote + job.payload + "/" : job.payload + "/"
        return args + ["--", source, target]
    }
    private static func request(_ job: TransferJob, op: String) -> [String: String] {
        ["op": op, "parent": job.destinationDirectory, "name": job.name, "token": job.id.uuidString.lowercased()]
    }
    public static func run(_ job: TransferJob,
                           update: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try Task.checkCancellation()
        let ssh = SSHClient(server: job.server)
        let rsync = try await findRsync()
        update(TransferUpdate(.preparing, "检查连接、源文件和目标目录…"))
        _ = try await ssh.probe()
        let inspection: Inspection
        if job.direction == .upload {
            inspection = try LocalStage.inspect(job.source)
            var r = request(job, op: "stage")
            // Check the remaining requirement on retries; rsync may need a second copy of the largest file.
            r["requiredBytes"] = String(inspection.bytes)
            let _: EmptyReply = try await ssh.request(r, as: EmptyReply.self)
        } else {
            inspection = try await ssh.request(["op": "inspect", "path": job.source], as: Inspection.self, timeout: nil)
            try LocalStage.prepare(job, requiredBytes: inspection.bytes)
        }
        try Task.checkCancellation()
        update(TransferUpdate(.transferring, "\(inspection.count) 个条目 · " + ByteCountFormatter.string(fromByteCount: inspection.bytes, countStyle: .file)))
        let result = try await ProcessRunner.run(rsync, try arguments(for: job, verify: false, ssh: ssh), timeout: nil) { chunk in
            let lines = chunk.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: "\r") }
            if let line = lines.last(where: { $0.contains("%") }) {
                update(TransferUpdate(.transferring, line.trimmingCharacters(in: .whitespaces)))
            }
        }
        _ = try result.checked()
        try Task.checkCancellation()
        update(TransferUpdate(.verifying, "再次读取源与目标内容，校验差异…"))
        let verification = try await ProcessRunner.run(rsync, try arguments(for: job, verify: true, ssh: ssh), timeout: nil)
        let differences = try verification.checked().trimmingCharacters(in: .whitespacesAndNewlines)
        guard differences.isEmpty else {
            throw RippleError("校验时发现差异，源文件可能正在变化。请停止修改源文件后重试。临时文件已保留。\n" + String(differences.prefix(1200)))
        }
        try Task.checkCancellation()
        if job.direction == .upload {
            let _: EmptyReply = try await ssh.request(request(job, op: "finish"), as: EmptyReply.self)
        } else { try LocalStage.finish(job) }
        update(TransferUpdate(.completed, job.finalPath))
    }
    public static func discard(_ job: TransferJob) async throws {
        guard !job.state.isActive else { throw RippleError("请先暂停任务。") }
        if job.direction == .upload {
            let _: EmptyReply = try await SSHClient(server: job.server).request(request(job, op: "discard"), as: EmptyReply.self)
        } else { try LocalStage.discard(job) }
    }
}

public enum LocalStage {
    private static func marker(_ job: TransferJob) -> [String: String] {
        ["token": job.id.uuidString.lowercased(), "name": job.name]
    }
    public static func inspect(_ path: String) throws -> Inspection {
        try Paths.validateAbsolute(path)
        guard path != "/" else { throw RippleError("请选择文件或文件夹，不要选择整个文件系统。") }
        var count = 0, bytes: Int64 = 0
        func walk(_ path: String) throws {
            try Task.checkCancellation()
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory || type == .typeSymbolicLink
            else { throw RippleError("不支持设备、套接字或管道文件：" + path) }
            count += 1
            if type == .typeRegular { bytes += (attrs[.size] as? NSNumber)?.int64Value ?? 0 }
            if type == .typeDirectory {
                for name in try FileManager.default.contentsOfDirectory(atPath: path) { try walk(Paths.join(path, name)) }
            }
        }
        try walk(path)
        return Inspection(count: count, bytes: bytes)
    }
    private static func check(_ job: TransferJob) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: job.stage)
        let markerPath = Paths.join(job.stage, "owner.json")
        let payloadAttrs = try fm.attributesOfItem(atPath: job.payload)
        let markerAttrs = try fm.attributesOfItem(atPath: markerPath)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              payloadAttrs[.type] as? FileAttributeType == .typeDirectory,
              markerAttrs[.type] as? FileAttributeType == .typeRegular,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: markerPath))) as? [String: String],
              value == marker(job) else { throw RippleError("临时目录归属不匹配，已停止操作。") }
    }
    public static func prepare(_ job: TransferJob, requiredBytes: Int64) throws {
        try Paths.validateAbsolute(job.destinationDirectory)
        try Paths.validateLeaf(job.name)
        guard !Paths.exists(job.finalPath) else { throw RippleError("目标已有同名文件。请选择另一个目标文件夹。") }
        let fm = FileManager.default
        if !Paths.exists(job.stage) {
            try fm.createDirectory(atPath: job.stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: marker(job)).write(to: URL(fileURLWithPath: Paths.join(job.stage, "owner.json")), options: .atomic)
            try fm.createDirectory(atPath: job.payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try check(job)
        let attrs = try fm.attributesOfFileSystem(forPath: job.destinationDirectory)
        guard let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value >= requiredBytes
        else { throw RippleError("目标磁盘空间不足。") }
    }
    public static func finish(_ job: TransferJob) throws {
        try check(job)
        guard try FileManager.default.contentsOfDirectory(atPath: job.payload) == [job.name],
              !Paths.exists(job.finalPath) else { throw RippleError("目标出现同名文件，或临时目录不完整。已保留传输数据。") }
        #if canImport(Darwin)
        let result = renamex_np(Paths.join(job.payload, job.name), job.finalPath, UInt32(RENAME_EXCL))
        guard result == 0 else { throw RippleError("无法交付文件：" + String(cString: strerror(errno))) }
        #else
        // Linux is used only for core tests; Foundation refuses an existing destination.
        try FileManager.default.moveItem(atPath: Paths.join(job.payload, job.name), toPath: job.finalPath)
        #endif
        try FileManager.default.removeItem(atPath: job.stage)
    }
    public static func discard(_ job: TransferJob) throws {
        if !Paths.exists(job.stage) { return }
        try check(job)
        try FileManager.default.removeItem(atPath: job.stage)
    }
}

import XCTest
@testable import RippleCore

final class CoreTests: XCTestCase {
    func testShellQuotingRoundTrip() async throws {
        let values = ["hello world", "中文文件夹", "a'b", "$(touch /tmp/never-rippleshare)", "line\nbreak", ""]
        for value in values {
            let result = try await ProcessRunner.run("/bin/sh", ["-c", "printf %s " + Paths.quote(value)])
            XCTAssertEqual(try result.checked(), value)
        }
    }
    func testServerRejectsOptionInjection() throws {
        for host in ["-oProxyCommand=bad", "a;whoami", "a\nb", "x@host", "$(id)"] {
            XCTAssertThrowsError(try Server(host: host, username: "root").validate())
        }
        XCTAssertNoThrow(try Server(host: "2001:db8::1", username: "test-user").validate())
        XCTAssertThrowsError(try Server(host: "host", port: 0, username: "u").validate())
        XCTAssertThrowsError(try Server(host: "host", username: "-u").validate())
    }
    func testLeafValidation() throws {
        for name in ["", ".", "..", "a/b", "a\0b"] { XCTAssertThrowsError(try Paths.validateLeaf(name)) }
        XCTAssertNoThrow(try Paths.validateLeaf("中文 ' ; $(x)"))
    }
    func testSSHNeverDisablesHostVerification() throws {
        let args = try SSHClient(server: Server(host: "example.com", username: "root")).arguments()
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ForwardAgent=no"))
    }
    func testTransferUsesProtectedArgumentsAndOwnStage() throws {
        let server = Server(host: "example.com", username: "root")
        let job = TransferJob(server: server, direction: .upload, source: "/tmp/a ' $(x)", destinationDirectory: "/remote folder")
        let args = try TransferEngine.arguments(for: job, verify: false, ssh: SSHClient(server: server))
        XCTAssertTrue(args.contains("--protect-args"))
        XCTAssertTrue(args.contains("--checksum"))
        XCTAssertTrue(args.contains("--partial"))
        XCTAssertEqual(args.last, "root@example.com:" + job.payload + "/")
        let verify = try TransferEngine.arguments(for: job, verify: true, ssh: SSHClient(server: server))
        XCTAssertTrue(verify.contains("--dry-run"))
        XCTAssertTrue(verify.contains("--delete"))
        XCTAssertFalse(verify.contains("--partial"))
    }
    func testProcessCapturesBothPipesAndFailure() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "printf stdout; printf stderr >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "stdout")
        XCTAssertEqual(result.error, "stderr")
        XCTAssertThrowsError(try result.checked())
    }
    func testProcessCancellation() async throws {
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], timeout: nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testTimeoutIsAnErrorNotUserCancellation() async throws {
        do {
            _ = try await ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch is RippleError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testBothOutputPipesDrainWithoutDeadlock() async throws {
        let command = "i=0; while [ $i -lt 3000 ]; do printf abcdefghijklmnopqrstuvwxyz; printf 01234567890123456789 >&2; i=$((i+1)); done"
        let result = try await ProcessRunner.run("/bin/sh", ["-c", command], timeout: 15)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 78000)
        XCTAssertEqual(result.error.count, 60000)
    }
    func testStatePersistenceAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StateStore(directory: directory)
        let server = Server(name: "测试", host: "example.com", username: "u")
        try store.save([server], as: "servers")
        XCTAssertEqual(try store.load("servers", as: [Server].self), [server])
        try Data("broken".utf8).write(to: directory.appendingPathComponent("servers.json"))
        XCTAssertThrowsError(try store.load("servers", as: [Server].self))
    }
    func testLocalStagePublishAndNoOverwrite() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let job = TransferJob(server: Server(host: "example.com", username: "u"), direction: .download,
                              source: "/remote/中文", destinationDirectory: root.path)
        try LocalStage.prepare(job, requiredBytes: 4)
        try LocalStage.prepare(job, requiredBytes: 4)
        try Data("test".utf8).write(to: URL(fileURLWithPath: Paths.join(job.payload, job.name)))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: job.finalPath))
        XCTAssertThrowsError(try LocalStage.finish(job))
        XCTAssertEqual(try String(contentsOfFile: job.finalPath), "keep")
        try fm.removeItem(atPath: job.finalPath)
        try LocalStage.finish(job)
        XCTAssertEqual(try String(contentsOfFile: job.finalPath), "test")
        XCTAssertFalse(Paths.exists(job.stage))
    }
    func testLocalStageRejectsSymlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let job = TransferJob(server: Server(host: "example.com", username: "u"), direction: .download,
                              source: "/remote/file", destinationDirectory: root.path)
        try fm.createSymbolicLink(atPath: job.stage, withDestinationPath: root.path)
        XCTAssertThrowsError(try LocalStage.prepare(job, requiredBytes: 0))
        XCTAssertThrowsError(try LocalStage.discard(job))
        XCTAssertTrue(Paths.exists(root.path))
    }
    func testInspectionPreservesSymlinksWithoutWalkingThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try Data("123".utf8).write(to: root.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)
        let inspection = try LocalStage.inspect(root.path)
        XCTAssertEqual(inspection.count, 3)
        XCTAssertEqual(inspection.bytes, 3)
    }
}

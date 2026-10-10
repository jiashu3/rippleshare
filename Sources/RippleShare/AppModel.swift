import AppKit
import SwiftUI
import RippleCore

@MainActor
final class AppModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selectedServer: UUID?
    @Published var connectedServer: Server?
    @Published var connecting = false
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = ""
    @Published var localEntries: [FileEntry] = []
    @Published var remoteEntries: [FileEntry] = []
    @Published var localSelection = Set<String>()
    @Published var remoteSelection = Set<String>()
    @Published var showHidden = false
    @Published var jobs: [TransferJob] = []
    @Published var error: String?
    @Published var status = "准备好连接"
    @Published var remoteLoading = false
    @Published var localLoading = false
    @Published var cleaningIDs = Set<UUID>()
    private var store: StateStore?
    private var worker: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var listing: Task<Void, Never>?
    private var localListing: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var listingGeneration = UUID()
    private var localGeneration = UUID()
    private var activeID: UUID?

    init() {
        do {
            let store = try StateStore(); self.store = store
            servers = try store.load("servers", as: [Server].self) ?? []
            jobs = try store.load("transfers", as: [TransferJob].self) ?? []
            for i in jobs.indices where jobs[i].state.isActive || jobs[i].state == .queued {
                jobs[i].state = .paused; jobs[i].detail = "上次会话已结束，点击继续恢复。"
            }
            selectedServer = servers.first?.id
        } catch { self.error = "无法读取本地配置：\(error.localizedDescription)" }
        refreshLocal()
    }
    var chosen: Server? { servers.first { $0.id == selectedServer } }
    var activeCount: Int { jobs.filter { $0.state.isActive || $0.state == .queued }.count }
    func persist() {
        do { try store?.save(servers, as: "servers"); try store?.save(jobs, as: "transfers") }
        catch { self.error = "无法保存配置：\(error.localizedDescription)" }
    }
    func save(_ server: Server) {
        do {
            try server.validate()
            if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server }
            else { servers.append(server) }
            selectedServer = server.id; persist()
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ server: Server) {
        if chosen?.id == server.id || connectedServer?.id == server.id { disconnect() }
        for i in jobs.indices where jobs[i].server.id == server.id && jobs[i].state == .queued {
            jobs[i].state = .paused
        }
        servers.removeAll { $0.id == server.id }
        selectedServer = servers.first?.id; persist()
    }
    func connect() {
        guard let server = chosen else { return }
        disconnect()
        let generation = UUID(); connectionGeneration = generation
        connecting = true; status = "正在连接 \(server.name)…"
        connection = Task {
            do {
                let capabilities = try await SSHClient(server: server).probe()
                try Task.checkCancellation()
                guard connectionGeneration == generation else { return }
                connectedServer = server; connecting = false
                remotePath = server.startPath.isEmpty ? capabilities.home : server.startPath
                status = "已连接 · \(server.host)"; refreshRemote()
            } catch {
                guard connectionGeneration == generation else { return }
                connecting = false; status = "未连接"
                if !(error is CancellationError) {
                    self.error = error.localizedDescription + "\n\n首次连接请先在终端确认服务器指纹；加密密钥请先加入 ssh-agent。连接编辑页可以复制 SSH 命令。"
                }
            }
        }
    }
    func disconnect() {
        connectionGeneration = UUID(); listingGeneration = UUID()
        connection?.cancel(); listing?.cancel()
        worker?.cancel()
        for i in jobs.indices where jobs[i].state == .queued { jobs[i].state = .paused }
        connectedServer = nil; connecting = false; remoteLoading = false
        remoteEntries = []; remoteSelection = []; remotePath = ""; status = "连接已断开"
        persist()
    }
    func refreshLocal(_ newPath: String? = nil) {
        let path = newPath ?? localPath
        localListing?.cancel()
        let generation = UUID(); localGeneration = generation; localLoading = true
        localListing = Task {
            do {
                let entries = try await Task.detached { try FileEntry.local(path) }.value
                guard localGeneration == generation else { return }
                localPath = path; localEntries = entries; localSelection = []; localLoading = false
            } catch {
                guard localGeneration == generation else { return }
                localLoading = false; self.error = error.localizedDescription
            }
        }
    }
    func refreshRemote(_ newPath: String? = nil) {
        guard let server = connectedServer else { return }
        let path = newPath ?? remotePath
        listing?.cancel()
        let generation = UUID(); listingGeneration = generation; remoteLoading = true
        listing = Task {
            do {
                let value = try await SSHClient(server: server).list(path)
                guard listingGeneration == generation else { return }
                remotePath = value.path; remoteEntries = value.entries; remoteSelection = []; remoteLoading = false
            } catch {
                guard listingGeneration == generation else { return }
                remoteLoading = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func visible(_ entries: [FileEntry], search: String) -> [FileEntry] {
        entries.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
    func enqueue(_ paths: [String], direction: Direction, target: String? = nil) {
        guard let server = connectedServer else { error = "请先连接服务器。"; return }
        let parent = target ?? (direction == .upload ? remotePath : localPath)
        for path in paths {
            guard !jobs.contains(where: { $0.source == path && $0.server.id == server.id && $0.direction == direction && $0.destinationDirectory == parent && $0.state != .completed }) else { continue }
            jobs.append(TransferJob(server: server, direction: direction, source: path, destinationDirectory: parent))
        }
        persist(); startNext()
    }
    func startNext() {
        guard worker == nil, let job = jobs.first(where: { $0.state == .queued }) else { return }
        activeID = job.id
        set(job.id, .preparing, "准备传输…")
        worker = Task {
            do {
                try await TransferEngine.run(job) { [self] value in
                    Task { @MainActor [self] in
                        guard self.activeID == job.id,
                              let current = self.jobs.first(where: { $0.id == job.id }), current.state.isActive else { return }
                        self.set(job.id, value.state, value.detail, save: value.state != .transferring)
                    }
                }
                set(job.id, .completed, job.finalPath)
                refreshLocal(); refreshRemote()
            } catch is CancellationError { set(job.id, .paused, "传输已暂停，临时数据已保留。") }
            catch { set(job.id, .failed, error.localizedDescription) }
            worker = nil; activeID = nil; startNext()
        }
    }
    private func set(_ id: UUID, _ state: TransferState, _ detail: String, save: Bool = true) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = state; jobs[i].detail = detail
        if save { persist() }
    }
    func pause(_ job: TransferJob) {
        if activeID == job.id { worker?.cancel() }
        else { set(job.id, .paused, "等待继续") }
    }
    func resume(_ job: TransferJob) {
        guard !cleaningIDs.contains(job.id) else { return }
        set(job.id, .queued, "等待继续"); startNext()
    }
    func discard(_ job: TransferJob) {
        guard !job.state.isActive && job.state != .queued, !cleaningIDs.contains(job.id) else { return }
        cleaningIDs.insert(job.id)
        Task {
            defer { cleaningIDs.remove(job.id) }
            do {
                if job.state != .completed { try await TransferEngine.discard(job) }
                jobs.removeAll { $0.id == job.id }; persist()
            } catch { self.error = "未能清理临时数据，任务已保留：\(error.localizedDescription)" }
        }
    }
    func createFolder(remote: Bool, name: String) {
        let parent = remote ? remotePath : localPath
        let server = connectedServer
        Task {
            do {
                try Paths.validateLeaf(name)
                if remote {
                    guard let server else { return }
                    try await SSHClient(server: server).mkdir(parent: parent, name: name)
                    refreshRemote()
                } else {
                    try FileManager.default.createDirectory(atPath: Paths.join(parent, name), withIntermediateDirectories: false)
                    refreshLocal()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func rename(_ entry: FileEntry, remote: Bool, name: String) {
        let server = connectedServer
        Task {
            do {
                try Paths.validateLeaf(name)
                if remote {
                    guard let server else { return }
                    try await SSHClient(server: server).rename(path: entry.path, name: name)
                    refreshRemote()
                } else {
                    try FileManager.default.moveItem(atPath: entry.path, toPath: Paths.join((entry.path as NSString).deletingLastPathComponent, name))
                    refreshLocal()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func chooseLocalFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "打开文件夹"
        if panel.runModal() == .OK, let url = panel.url { refreshLocal(url.path) }
    }
    func stopForQuit() {
        worker?.cancel(); connection?.cancel(); listing?.cancel()
        for i in jobs.indices where jobs[i].state.isActive || jobs[i].state == .queued { jobs[i].state = .paused }
        persist()
    }
}

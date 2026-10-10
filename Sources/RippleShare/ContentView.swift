import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RippleCore

private let accent = Color(red: 0.10, green: 0.51, blue: 0.46)
private let remoteType = "hk.ripplelab.rippleshare.remote-file"

@MainActor struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Server?
    @State private var deleting: Server?
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 225)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    BrowserPane(remote: false)
                    Divider()
                    BrowserPane(remote: true)
                }
                Divider()
                TransferShelf()
                Divider()
                HStack {
                    Circle().fill(model.connectedServer == nil ? Color.secondary : accent).frame(width: 6, height: 6)
                    Text(model.status)
                    Spacer()
                    Text("RippleShare 0.1 · by RippleLab").foregroundStyle(.tertiary)
                }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { server in ServerEditor(server: server) { model.save($0) } }
        .alert("需要处理", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("删除这个连接？服务器里的文件不会被删除。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除连接", role: .destructive) { if let server = deleting { model.remove(server) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        }
    }
    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("你的电脑，与服务器。") .font(.system(size: 21, weight: .semibold))
                Text("浏览 · 传输 · 自在连接").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $model.showHidden) { Image(systemName: "eye") }.toggleStyle(.button).help("显示隐藏文件")
            if model.connectedServer != nil || model.connecting {
                Button("断开连接", action: model.disconnect)
            } else {
                Button(action: model.connect) { Label("连接服务器", systemImage: "bolt.horizontal") }
                    .buttonStyle(.borderedProminent).disabled(model.chosen == nil)
            }
        }.padding(22)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "water.waves").font(.system(size: 25, weight: .semibold)).foregroundStyle(accent)
                Text("RippleShare").font(.system(size: 21, weight: .bold, design: .rounded))
            }.padding(.top, 35).padding(.horizontal, 19).padding(.bottom, 34)
            Text("工作空间").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 20)
            Button { model.chooseLocalFolder() } label: {
                Label("这台 Mac", systemImage: "laptopcomputer").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(14).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9)).padding(10)
            HStack {
                Text("服务器").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { editing = Server() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("添加服务器")
            }.padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 10)
            if model.servers.isEmpty {
                Text("添加你的第一台服务器，\n在这里建立连接。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(5).padding(20)
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.servers) { server in
                        Button {
                            if model.selectedServer != server.id { model.disconnect() }
                            model.selectedServer = server.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name.isEmpty ? server.host : server.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(server.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.connectedServer?.id == server.id { Circle().fill(accent).frame(width: 6, height: 6) }
                            }.padding(11).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(model.selectedServer == server.id ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            .contextMenu {
                                Button("编辑连接") { editing = server }
                                Button("删除连接", role: .destructive) { deleting = server }
                            }
                    }
                }.padding(.horizontal, 10)
            }
            Button { editing = Server() } label: { Label("添加服务器", systemImage: "plus.circle").frame(maxWidth: .infinity) }
                .padding(14)
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 7) {
                Text("由你掌控的连接").font(.caption.weight(.medium))
                Text("按需连接，随时断开。\n文件直接往返电脑与服务器。")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(4)
                Link("涟漪工场 ↗", destination: URL(string: "https://www.ripplelab.hk")!).font(.caption2)
            }.padding(20)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

@MainActor struct BrowserPane: View {
    @EnvironmentObject var model: AppModel
    let remote: Bool
    @State private var pathText = ""
    @State private var search = ""
    @State private var targeted = false
    @State private var folderDialog = false
    @State private var nameText = ""
    @State private var renaming: FileEntry?
    var path: String { remote ? model.remotePath : model.localPath }
    var entries: [FileEntry] { model.visible(remote ? model.remoteEntries : model.localEntries, search: search) }
    var selection: Binding<Set<String>> { remote ? $model.remoteSelection : $model.localSelection }
    var available: Bool { !remote || model.connectedServer != nil }
    var loading: Bool { remote ? model.remoteLoading : model.localLoading }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: remote ? "server.rack" : "laptopcomputer").foregroundStyle(accent)
                Text(remote ? (model.connectedServer?.name ?? "服务器") : "这台 Mac").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { navigate((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent) }
                    label: { Image(systemName: "arrow.up") }.disabled(!available || path == "/").help("上级目录")
                Button { nameText = ""; folderDialog = true } label: { Image(systemName: "folder.badge.plus") }.disabled(!available).help("新建文件夹")
                Button { navigate(path) } label: { Image(systemName: "arrow.clockwise") }.disabled(!available).help("刷新")
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField(remote && !available ? "连接后浏览服务器目录" : "/path/to/folder", text: $pathText)
                    .textFieldStyle(.plain).font(.system(.caption, design: .monospaced))
                    .onSubmit { navigate(pathText) }.disabled(!available)
                if !remote { Button { model.chooseLocalFolder() } label: { Image(systemName: "ellipsis") }.buttonStyle(.plain) }
            }.padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 16)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("筛选当前目录", text: $search).textFieldStyle(.plain).font(.caption)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if !available {
                VStack(spacing: 16) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(accent.opacity(0.7))
                    Text(model.connecting ? "正在建立连接…" : "另一端，等你连接").font(.title3.weight(.medium))
                    Text("选择一台服务器，开始浏览和传输文件。") .font(.caption).foregroundStyle(.secondary)
                    if model.connecting { ProgressView().controlSize(.small) }
                    else { Button("连接服务器", action: model.connect).disabled(model.chosen == nil) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.isSymlink ? "link" : (entry.isDirectory ? "folder.fill" : "doc"))
                                .foregroundStyle(entry.isDirectory ? accent : .secondary).font(.system(size: 20)).frame(width: 27)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Text(entry.isDirectory ? "文件夹" : (entry.isSymlink ? "符号链接" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Date(timeIntervalSince1970: entry.modified), format: .dateTime.month(.twoDigits).day(.twoDigits))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4).contentShape(Rectangle()).tag(entry.path)
                            .onTapGesture(count: 2) { if entry.isDirectory { navigate(entry.path) } }
                            .onDrag { provider(entry) }
                            .contextMenu {
                                if entry.isDirectory { Button("打开文件夹") { navigate(entry.path) } }
                                Button(remote ? "下载到左侧目录" : "上传到右侧目录") {
                                    model.enqueue([entry.path], direction: remote ? .download : .upload)
                                }.disabled(model.connectedServer == nil)
                                Divider()
                                Button("重命名") { renaming = entry; nameText = entry.name }
                                Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
                            }
                    }
                }.listStyle(.inset).overlay {
                    if entries.isEmpty && !loading {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(search.isEmpty ? "文件夹是空的" : "没有匹配的文件").font(.caption).foregroundStyle(.secondary)
                            if search.isEmpty { Text("把文件拖到这里开始传输").font(.caption2).foregroundStyle(.tertiary) }
                        }.allowsHitTesting(false)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(entries.count) 个项目").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.enqueue(Array(selection.wrappedValue).sorted(), direction: remote ? .download : .upload)
                } label: { Label(remote ? "下载所选" : "上传所选", systemImage: remote ? "arrow.down" : "arrow.up") }
                    .disabled(selection.wrappedValue.isEmpty || model.connectedServer == nil)
            }.padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? accent.opacity(0.08) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(targeted ? accent : .clear, lineWidth: 2))
        .onDrop(of: remote ? [UTType.fileURL.identifier] : [remoteType], isTargeted: $targeted, perform: receive)
        .onAppear { pathText = path }
        .onChange(of: path) { pathText = $0 }
        .alert("新建文件夹", isPresented: $folderDialog) {
            TextField("文件夹名称", text: $nameText)
            Button("创建") { model.createFolder(remote: remote, name: nameText) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("新名称", text: $nameText)
            Button("保存") { if let entry = renaming { model.rename(entry, remote: remote, name: nameText) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }
    private func navigate(_ path: String) { if remote { model.refreshRemote(path) } else { model.refreshLocal(path) } }
    private func provider(_ entry: FileEntry) -> NSItemProvider {
        if !remote { return NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL) }
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(RemoteDrag(serverID: model.connectedServer?.id, path: entry.path))
        provider.registerDataRepresentation(forTypeIdentifier: remoteType, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard model.connectedServer != nil else { return false }
        let target = path, serverID = model.connectedServer?.id
        for provider in providers {
            if remote {
                provider.loadObject(ofClass: NSURL.self) { item, _ in
                    guard let url = item as? URL, url.isFileURL else { return }
                    Task { @MainActor in
                        guard model.connectedServer?.id == serverID else { return }
                        model.enqueue([url.path], direction: .upload, target: target)
                    }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: remoteType) { data, _ in
                    guard let data, let drag = try? JSONDecoder().decode(RemoteDrag.self, from: data) else { return }
                    Task { @MainActor in
                        guard drag.serverID == model.connectedServer?.id else { return }
                        model.enqueue([drag.path], direction: .download, target: target)
                    }
                }
            }
        }
        return !providers.isEmpty
    }
}

private struct RemoteDrag: Codable { let serverID: UUID?; let path: String }

@MainActor struct TransferShelf: View {
    @EnvironmentObject var model: AppModel
    @State private var clearing: TransferJob?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("传输任务", systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                if model.activeCount > 0 { Text("\(model.activeCount)").font(.caption).padding(.horizontal, 7).background(accent.opacity(0.12), in: Capsule()) }
                Spacer()
                Text("先接收 · 再校验 · 完整交付").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if model.jobs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right").font(.title2).foregroundStyle(accent.opacity(0.7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("拖动文件，让两端相连").font(.subheadline)
                        Text("支持整个文件夹；中断后可以继续，已有文件不会被覆盖。") .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 24).frame(height: 77)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs.reversed()) { job in
                            HStack(spacing: 12) {
                                Image(systemName: job.direction == .upload ? "arrow.up.circle" : "arrow.down.circle").font(.title2).foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(job.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text(job.state.label).font(.caption2).foregroundStyle(job.state == .failed ? Color.orange : .secondary)
                                    }
                                    Text(job.detail.isEmpty ? job.server.name : job.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                }
                                Spacer()
                                if job.state.isActive { ProgressView().controlSize(.small) }
                                if job.state.isActive || job.state == .queued {
                                    Button("暂停") { model.pause(job) }
                                } else if job.state != .completed {
                                    Button("继续") { model.resume(job) }
                                    Button { clearing = job } label: { Image(systemName: "trash") }.help("清理临时文件并移除任务")
                                } else {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                    Button { model.discard(job) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("移除完成记录")
                                }
                            }.padding(.horizontal, 20).padding(.vertical, 10)
                                .disabled(model.cleaningIDs.contains(job.id))
                            Divider().padding(.leading, 55)
                        }
                    }
                }.frame(height: 145)
            }
        }
        .confirmationDialog("清理这次任务的临时文件？源文件不会被删除。", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button("清理并移除", role: .destructive) { if let job = clearing { model.discard(job) }; clearing = nil }
            Button("取消", role: .cancel) { clearing = nil }
        }
    }
}

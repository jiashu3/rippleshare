import AppKit
import SwiftUI
import RippleCore

@MainActor struct ServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    var save: (Server) -> Void
    @State private var error: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(server.name.isEmpty ? "建立一个新连接" : "编辑连接").font(.title2.weight(.semibold))
            Text("SSH 密钥连接 · Linux / macOS 服务器").font(.subheadline).foregroundStyle(.secondary)
            Form {
                TextField("连接名称", text: $server.name, prompt: Text("我的服务器"))
                TextField("主机 / IP", text: $server.host, prompt: Text("server.example.com"))
                TextField("SSH 端口", value: $server.port, formatter: NumberFormatter())
                TextField("用户名", text: $server.username, prompt: Text("ubuntu"))
                HStack {
                    TextField("私钥路径", text: $server.identityFile, prompt: Text("留空则使用 SSH 配置与 ssh-agent"))
                    Button("选择…") {
                        let panel = NSOpenPanel(); panel.showsHiddenFiles = true
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                        if panel.runModal() == .OK, let url = panel.url { server.identityFile = url.path }
                    }
                }
                TextField("起始目录", text: $server.startPath, prompt: Text("留空则进入用户主目录"))
            }.textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                Label("首次连接", systemImage: "key.horizontal").font(.subheadline.weight(.semibold))
                Text("先在终端连接一次，核对并确认服务器指纹。加密私钥可通过 ssh-add 加入系统代理；应用不会存储密码或复制私钥。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(copied ? "已复制 SSH 命令" : "复制 SSH 命令") {
                    do {
                        try server.validate()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SSHClient(server: server).terminalSetupCommand, forType: .string)
                        copied = true
                    } catch { self.error = error.localizedDescription }
                }
                Text("传输需要两端 rsync 3+，服务器还需 Python 3.8+。Mac 可运行 brew install rsync。")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(14).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存连接") {
                    do {
                        server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        server.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
                        try server.validate()
                        if server.name.isEmpty { server.name = server.host }
                        save(server); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
    }
}

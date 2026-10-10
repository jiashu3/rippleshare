import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            model?.stopForQuit()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
@MainActor struct RippleShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .frame(minWidth: 1020, minHeight: 700)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1250, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("连接") {
                Button("连接服务器") { model.connect() }.keyboardShortcut("k").disabled(model.chosen == nil)
                Button("断开连接") { model.disconnect() }.keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Toggle("显示隐藏文件", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                Button("刷新") { model.refreshLocal(); model.refreshRemote() }.keyboardShortcut("r")
            }
        }
    }
}

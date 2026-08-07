import AppKit
import SwiftUI

@main
struct IOSCPYDreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ioscpy dream") {
            RootView(model: model)
                .frame(minWidth: 320, minHeight: 480)
                .onAppear { model.launch() }
        }
        .defaultSize(width: 860, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("设置…") { model.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("控制") {
                Button("主屏幕") { model.systemAction(1) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("App 切换器") { model.systemAction(4) }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("锁定") { model.systemAction(2) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("手机黑屏") { model.toggleBlackScreen() }.keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("断开") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("诊断") {
                Button("在 Finder 中显示最新日志") {
                    DiagnosticsLogger.shared.revealInFinder()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLogger.shared.logMessage("app_terminate", "normal termination")
        DiagnosticsLogger.shared.flush()
    }
}

import AppKit
import SwiftUI

@main
struct ReSignApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ReSign", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .task { model.start() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    Task { await model.scanDevices() }
                }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }.keyboardShortcut(",")
            }
        }
        MenuBarExtra("ReSign", systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "signature") {
            MenuContent(model: model)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.isBusy ? "正在续签…" : "托管 \(model.library.apps.count) 个应用")
        Button("打开 ReSign") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("扫描设备并续签") { Task { await model.scanDevices() } }
            .disabled(model.isBusy)
        Divider()
        Button("退出 ReSign") { NSApp.terminate(nil) }
            .disabled(model.isBusy || model.isLoggingIn)
    }
}

import SwiftUI

struct OpenPhonicApp: App {
    @Local private var model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
                .task {
                    // look for a new version a few seconds after launch
                    try? await Task.sleep(for: .seconds(3))
                    await model.checkForUpdate()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuova produzione") { model.selection = nil; model.showingHome = true }
                    .keyboardShortcut("n")
                Button("Apri file…") { openFiles(model) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") {
                    model.updateStatus = "Controllo in corso…"
                    Task { await model.checkForUpdate(userAsked: true) }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let id = UserDefaults.standard.string(forKey: "preset") ?? "podcast"
            AppModel.shared.add(urls, preset: Preset.all.first { $0.id == id } ?? Preset.all[0])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

@MainActor
func openFiles(_ model: AppModel, preset: Preset = Preset.all[0]) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
    panel.message = "Scegli uno o più file audio o video da elaborare"
    if panel.runModal() == .OK { model.add(panel.urls, preset: preset) }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 280)
                    .padding(.vertical, 14)
                    .padding(.leading, 14)
                Group {
                    if model.showingHome || model.selected == nil {
                        HomeView().transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else if let p = model.selected {
                        switch p.status {
                        case .setup, .failed: SetupView(id: p.id).id(p.id)
                        case .queued, .processing: ProcessingView(id: p.id).id(p.id)
                        case .done: ResultView(id: p.id).id(p.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: model.selection)
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: model.selected?.status)
            }
        }
        .ignoresSafeArea()
    }
}

import AppIntents

struct SyncRingIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Ring"
    static let description = IntentDescription("Sync your paired ring to Open Oura.")
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await RingSync.shared.syncFromShortcut()
        return .result(dialog: "Open Oura finished syncing your ring.")
    }
}

struct OpenOuraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncRingIntent(),
            phrases: ["Sync my ring with \(.applicationName)"],
            shortTitle: "Sync Ring",
            systemImageName: "arrow.clockwise"
        )
    }
}

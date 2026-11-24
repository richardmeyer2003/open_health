import SwiftUI

/// Pending-sync state and export writes are serialized on this queue.
final class ScriptableIntegration: ObservableObject, @unchecked Sendable {
    static let shared = ScriptableIntegration()
    static let exportFolderName = "Scriptable"
    private let queue = DispatchQueue(label: "md.thomas.openoura.scriptable", qos: .utility)
    private let defaults: UserDefaults
    private let documentsDirectory: URL
    private let prefix = "scriptable."
    @Published private(set) var enabled: Bool
    @Published private(set) var lastExportAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var working = false

    init(defaults: UserDefaults = .standard, documentsDirectory: URL = .documentsDirectory) {
        let prefix = "scriptable."
        self.defaults = defaults
        self.documentsDirectory = documentsDirectory
        enabled = defaults.bool(forKey: prefix + "enabled")
        let last = defaults.double(forKey: prefix + "documents-last-export-at")
        lastExportAt = last > 0 ? Date(timeIntervalSince1970: last) : nil
        error = defaults.string(forKey: prefix + "documents-error")

        // Keep the user's opt-in and sync metadata when retiring the picker.
        for key in ["folder-bookmark", "folder-name", "last-export-at", "error"] {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        queue.async {
            self.defaults.set(enabled, forKey: self.prefix + "enabled")
            if !enabled { self.defaults.removeObject(forKey: self.prefix + "pending-sync") }
        }
    }

    /// Runs for every successful manual or automatic sync, including zero new events.
    func synchronized(at date: Date, source: String, report: SyncReport) {
        queue.async {
            let metadata: [String: Any] = [
                "last_successful_at": ISO8601DateFormatter().string(from: date),
                "last_successful_source": source == "manual" ? "manual" : "automatic", "events_received": report.eventsSynced,
                "events_inserted": report.inserted
            ]
            self.defaults.set(metadata, forKey: self.prefix + "sync")
            if self.defaults.bool(forKey: self.prefix + "enabled") {
                self.defaults.set(date.timeIntervalSince1970, forKey: self.prefix + "pending-sync")
            }
        }
    }

    func summaryReady(_ summary: Summary, generatedAt: Date, syncedAt: Date?) {
        queue.async {
            guard self.defaults.bool(forKey: self.prefix + "enabled"),
                  let syncedAt,
                  self.defaults.double(forKey: self.prefix + "pending-sync") == syncedAt.timeIntervalSince1970 else { return }
            self.export(summary, generatedAt: generatedAt, reason: "sync")
        }
    }

    func exportNow() {
        working = true
        queue.async {
            guard self.defaults.bool(forKey: self.prefix + "enabled") else {
                DispatchQueue.main.async { self.working = false }
                return
            }
            guard let summary = SummaryCache.load() else {
                self.failed(ExportError.message("Sync the ring before exporting."))
                return
            }
            let lastSync = self.defaults.double(forKey: "ring.last-successful-sync-at")
            if lastSync > (SummaryCache.writtenAt?.timeIntervalSince1970 ?? 0) {
                self.failed(ExportError.message("Wait for the post-sync data refresh to finish, then export again."))
                return
            }
            self.export(summary, generatedAt: SummaryCache.writtenAt, reason: "manual")
        }
    }

    func resetSync() {
        queue.async {
            self.defaults.removeObject(forKey: self.prefix + "pending-sync")
            self.defaults.removeObject(forKey: self.prefix + "sync")
        }
    }

    private func export(_ summary: Summary, generatedAt: Date?, reason: String) {
        DispatchQueue.main.async { self.working = true }
        do {
            guard summary.error == nil else { throw ExportError.message("Wait for a successful data refresh before exporting.") }
            var metadata = defaults.dictionary(forKey: prefix + "sync") ?? [
                "last_successful_at": NSNull(), "last_successful_source": NSNull(),
                "events_received": NSNull(), "events_inserted": NSNull()
            ]
            // Preserve the real last-sync date across upgrades from an older build.
            if metadata["last_successful_at"] is NSNull {
                let previous = defaults.double(forKey: "ring.last-successful-sync-at")
                if previous > 0 {
                    metadata["last_successful_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: previous))
                }
            }
            let data = try ScriptableSnapshot.data(summary: summary, sync: metadata, generatedAt: generatedAt,
                                                   reason: reason, hourly: HourlyHR.load(days: 2))
            try Self.replace(data, at: exportDestination())
            let completedAt = Date()
            defaults.set(completedAt.timeIntervalSince1970, forKey: prefix + "documents-last-export-at")
            if reason == "sync" { defaults.removeObject(forKey: prefix + "pending-sync") }
            clearError()
            DispatchQueue.main.async { self.lastExportAt = completedAt; self.working = false }
        } catch { failed(error) }
    }

    private func exportDestination() throws -> URL {
        var folder = documentsDirectory.appendingPathComponent(Self.exportFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder.appendingPathComponent(ScriptableSnapshot.filename)
    }

    /// Coordinate with Files and Scriptable readers, and preserve the previous export on write failure.
    static func replace(_ data: Data, at destination: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func clearError() {
        defaults.removeObject(forKey: prefix + "documents-error")
        DispatchQueue.main.async { self.error = nil }
    }

    private func failed(_ error: Error) {
        let message = error.localizedDescription
        defaults.set(message, forKey: prefix + "documents-error")
        DispatchQueue.main.async { self.error = message; self.working = false }
        dlog("scriptable", "export failed: \(message)")
    }

    private enum ExportError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

struct ScriptableIntegrationSection: View {
    @ObservedObject private var integration = ScriptableIntegration.shared

    var body: some View {
        Section {
            Toggle("Enable Scriptable Integration", isOn: Binding(get: { integration.enabled }, set: integration.setEnabled))
            if integration.enabled {
                Button(action: integration.exportNow) {
                    HStack {
                        Text("Export Now")
                        Spacer()
                        if integration.working { ProgressView() }
                    }
                }
                .disabled(integration.working)
                LabeledContent("Last successful export") {
                    if let date = integration.lastExportAt { Text(date, format: .dateTime.month().day().hour().minute().second()) }
                    else { Text("Never") }
                }
                if let error = integration.error {
                    Text(error).font(.footnote).foregroundStyle(Obs.alert)
                }
            }
        } header: {
            Text("Scriptable Integration")
        } footer: {
            if integration.enabled {
                Text("After each successful sync, saves health data to Files → On My iPhone → Open Oura → \(ScriptableIntegration.exportFolderName) → \(ScriptableSnapshot.filename).")
            }
        }
    }
}

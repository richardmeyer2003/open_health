import SwiftUI
import UniformTypeIdentifiers

/// All authorization, pending-sync state, and writes are serialized on this queue.
final class ScriptableIntegration: ObservableObject, @unchecked Sendable {
    static let shared = ScriptableIntegration()
    private let queue = DispatchQueue(label: "md.thomas.openoura.scriptable", qos: .utility)
    private let defaults: UserDefaults
    private let prefix = "scriptable."
    @Published private(set) var enabled: Bool
    @Published private(set) var folderName: String
    @Published private(set) var lastExportAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var working = false

    init(defaults: UserDefaults = .standard) {
        let prefix = "scriptable."
        self.defaults = defaults
        enabled = defaults.bool(forKey: prefix + "enabled")
        folderName = defaults.string(forKey: prefix + "folder-name") ?? "Choose a folder under On My iPhone"
        let last = defaults.double(forKey: prefix + "last-export-at")
        lastExportAt = last > 0 ? Date(timeIntervalSince1970: last) : nil
        error = defaults.string(forKey: prefix + "error")
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        queue.async {
            self.defaults.set(enabled, forKey: self.prefix + "enabled")
            if !enabled { self.defaults.removeObject(forKey: self.prefix + "pending-sync") }
        }
    }

    func chooseFolder(_ url: URL) {
        working = true
        queue.async {
            do {
                guard url.startAccessingSecurityScopedResource() else {
                    throw ExportError.message("Folder access was denied. Choose the folder again.")
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
                guard values.isDirectory == true else { throw ExportError.message("Choose a folder.") }
                guard values.isUbiquitousItem != true else {
                    throw ExportError.message("Choose a local folder under On My iPhone.")
                }
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                self.defaults.set(bookmark, forKey: self.prefix + "folder-bookmark")
                self.defaults.set(url.lastPathComponent, forKey: self.prefix + "folder-name")
                self.clearError()
                DispatchQueue.main.async { self.folderName = url.lastPathComponent; self.working = false }
            } catch { self.failed(error) }
        }
    }

    /// Runs for every successful manual or automatic sync, including zero new events.
    func synchronized(at date: Date, source: String, report: SyncReport) {
        queue.async {
            let metadata: [String: Any] = [
                "last_successful_at": ISO8601DateFormatter().string(from: date),
                "last_successful_source": source, "events_received": report.eventsSynced,
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
            guard let bookmark = defaults.data(forKey: prefix + "folder-bookmark") else {
                throw ExportError.message("Choose an export folder under On My iPhone.")
            }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            guard folder.startAccessingSecurityScopedResource() else {
                throw ExportError.message("Folder access has expired. Choose the folder again.")
            }
            defer { folder.stopAccessingSecurityScopedResource() }
            if stale {
                let renewed = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(renewed, forKey: prefix + "folder-bookmark")
            }
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
            try Self.replace(data, at: folder.appendingPathComponent(ScriptableSnapshot.filename))
            let completedAt = Date()
            defaults.set(completedAt.timeIntervalSince1970, forKey: prefix + "last-export-at")
            if reason == "sync" { defaults.removeObject(forKey: prefix + "pending-sync") }
            clearError()
            DispatchQueue.main.async { self.lastExportAt = completedAt; self.working = false }
        } catch { failed(error) }
    }

    /// Coordination protects Files-provider access. Atomic writing preserves the previous file on failure.
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
        defaults.removeObject(forKey: prefix + "error")
        DispatchQueue.main.async { self.error = nil }
    }

    private func failed(_ error: Error) {
        let message = error.localizedDescription
        defaults.set(message, forKey: prefix + "error")
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
    @State private var selectingFolder = false

    var body: some View {
        Section {
            Toggle("Enable Scriptable Integration", isOn: Binding(get: { integration.enabled }, set: integration.setEnabled))
            if integration.enabled {
                Button { selectingFolder = true } label: {
                    LabeledContent("Export folder", value: integration.folderName)
                }
                .disabled(integration.working)
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
            Text("Saves open-oura-widget.json after a successful ring sync. Choose the local folder bookmarked in Scriptable. This file includes your health data.")
        }
        .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): integration.chooseFolder(url)
            case .failure: break // Cancelling the picker leaves the existing authorization intact.
            }
        }
    }
}

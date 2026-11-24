import SwiftUI
import WidgetKit

struct ActivityWidgetSnapshot: Codable, Equatable {
    let day: String
    let steps: Int?
    let activeCalories: Int?
    let movement: [Double]

    var reportURL: URL? {
        URL(string: "openoura://activity/\(day)")
    }
}

enum ActivityWidgetStore {
    static let kind = "OpenOuraActivity"
    private static let appGroup = "group.com.richardmeyer2003.openoura"

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("activity-widget.json")
    }

    static func load() -> ActivityWidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ActivityWidgetSnapshot.self, from: data)
    }

    static var sharingAvailable: Bool { file != nil }

    static var diagnosticReport: String {
        let heading = "Requested App Group: \(appGroup)"
        guard let file else {
            return heading + "\nShared container unavailable. The installed app needs this App Group in its signing entitlements and provisioning profile."
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            return heading + "\nShared container available. No activity snapshot has been written yet."
        }
        do {
            let data = try Data(contentsOf: file)
            let snapshot = try JSONDecoder().decode(ActivityWidgetSnapshot.self, from: data)
            return heading + "\nShared snapshot readable. Day: \(snapshot.day), movement buckets: \(snapshot.movement.count)."
        } catch {
            return heading + "\nSnapshot could not be read: \(error.localizedDescription)"
        }
    }

    /// Called on the host app's serial summary-cache queue.
    static func publish(_ snapshot: ActivityWidgetSnapshot?, forceReload: Bool = false) {
        guard let file else {
            NSLog("Open Oura Activity widget: shared container unavailable for %@", appGroup)
            return
        }
        do {
            if let snapshot {
                if load() != snapshot {
                    let data = try JSONEncoder().encode(snapshot)
                    try data.write(to: file, options: .atomic)
                } else if !forceReload { return }
            } else {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                } else if !forceReload { return }
            }
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } catch {
            NSLog("Open Oura could not update the Activity widget snapshot: %@", error.localizedDescription)
        }
    }
}

/// Movement from the ring's 15-minute MET-above-rest buckets.
struct MovementRidge: View {
    let profile: [Double]
    var height: CGFloat = 44
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard profile.count > 1 else { return }
            let peak = max(profile.max() ?? 0, 0.5)
            let last = profile.count - 1

            func point(at index: Int) -> CGPoint {
                let fraction = min(1, max(0, profile[index] / peak))
                return CGPoint(x: size.width * CGFloat(index) / CGFloat(last),
                               y: size.height * (1 - CGFloat(fraction)))
            }

            var line = Path()
            line.move(to: point(at: 0))
            for index in 1...last {
                line.addLine(to: point(at: index))
            }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.14)))
            context.stroke(line, with: .color(color.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

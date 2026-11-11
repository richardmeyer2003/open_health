import SwiftUI
import WidgetKit

private struct ActivityEntry: TimelineEntry {
    let date: Date
    let activity: ActivityWidgetSnapshot?

    static func preview(at date: Date) -> Self {
        ActivityEntry(date: date, activity: ActivityWidgetSnapshot(
            day: "2026-11-10", steps: 2_800, activeCalories: 353,
            movement: [0, 0, 0, 0, 0, 0, 3.1, 0, 1.8, 0.3, 0.6, 1.4, 1.2, 1.3,
                       0.7, 0.6, 0.9, 0.4, 1.9, 0.9, 1.6, 0.3, 0, 0, 0, 0, 0, 0]
        ))
    }
}

private struct ActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActivityEntry { .preview(at: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(context.isPreview ? .preview(at: .now) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> ActivityEntry {
        ActivityEntry(date: .now, activity: ActivityWidgetStore.load())
    }
}

private struct ActivityWidgetView: View {
    let entry: ActivityEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var chartColor: Color {
        if renderingMode == .accented { return .primary }
        return colorScheme == .dark
            ? Color(red: 0.65, green: 0.77, blue: 0.92)
            : Color(red: 0.24, green: 0.38, blue: 0.57)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label {
                    Text("Activity").tracking(1.2).textCase(.uppercase)
                } icon: {
                    Image(systemName: "figure.walk")
                }
                .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                let steps = entry.activity?.steps?.formatted() ?? "–"
                let calories = entry.activity?.activeCalories?.formatted() ?? "–"
                Text("\(steps) steps · \(calories) kcal")
                    .monospacedDigit()
                    .accessibilityLabel("\(steps) steps, \(calories) active kilocalories")
                if entry.activity != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            GeometryReader { geometry in
                MovementRidge(profile: entry.activity?.movement ?? [],
                              height: geometry.size.height, color: chartColor)
                    .widgetAccentable()
            }
        }
        .privacySensitive()
        .widgetURL(entry.activity?.reportURL)
        .containerBackground(for: .widget) {
            if colorScheme == .dark { Color(red: 0.10, green: 0.14, blue: 0.22) }
            else { Color(red: 0.92, green: 0.95, blue: 1.00) }
        }
    }
}

@main
struct OpenOuraActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ActivityWidgetStore.kind, provider: ActivityProvider()) { entry in
            ActivityWidgetView(entry: entry)
        }
        .configurationDisplayName("Activity")
        .description("Steps, active calories, and movement from your latest ring sync.")
        .supportedFamilies([.systemMedium])
    }
}

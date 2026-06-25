// TonoWidget.swift
// WidgetKit small / medium / lock-screen widget showing daily rewrite usage
// and the most recent analysis result.
//
// Xcode setup:
//   1. File > New > Target > Widget Extension, name "TonoWidget"
//   2. Add App Group "group.com.tonocoach.shared" to the widget target
//   3. PRODUCT_BUNDLE_IDENTIFIER: com.tonocoach.app.widget
//
// Data flow: keyboard extension writes to App Group UserDefaults after each
// successful analysis. The host app calls WidgetCenter.shared.reloadAllTimelines()
// on foreground so the widget reflects the latest state within seconds.

import WidgetKit
import SwiftUI

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

struct UsageEntry: TimelineEntry {
    let date: Date
    let used: Int
    let limit: Int          // -1 = unlimited (Pro)
    let isPro: Bool
    let lastPerception: String?
    let lastRiskLevel: String?  // "low" | "medium" | "high"

    var displayLimit: Int { isPro ? 0 : max(limit, 0) }
    var remaining: Int { isPro ? Int.max : max(0, displayLimit - used) }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), used: 4, limit: 10, isPro: false,
                   lastPerception: "Lands cleanly. ✅", lastRiskLevel: "low")
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh at midnight so the daily counter resets, or in 1 hour to pick
        // up new analyses even if the host app didn't trigger an explicit reload.
        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        let next = min(nextHour, midnight)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> UsageEntry {
        let d = UserDefaults(suiteName: "group.com.tonocoach.shared") ?? .standard
        let used  = d.integer(forKey: "tc.widgetUsedToday")
        let limit = d.object(forKey: "tc.widgetDailyLimit") as? Int ?? 10
        let isPro = limit == -1 || d.bool(forKey: "tc.proUnlocked")
        return UsageEntry(
            date: Date(),
            used: used,
            limit: limit,
            isPro: isPro,
            lastPerception: d.string(forKey: "tc.lastPerception"),
            lastRiskLevel: d.string(forKey: "tc.lastRiskLevel")
        )
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

private func riskColor(_ level: String?) -> Color {
    switch level {
    case "low":  return .green
    case "high": return .red
    default:     return .yellow
    }
}

// ---------------------------------------------------------------------------
// Small widget
// ---------------------------------------------------------------------------

private struct SmallView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.purple)
                Text("Tono")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.purple)
            }

            Spacer()

            if entry.isPro {
                Text("∞")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Pro · unlimited")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Text("\(entry.used)/\(entry.displayLimit)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("rewrites today")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                if entry.displayLimit > 0 {
                    ProgressView(value: Double(entry.used), total: Double(entry.displayLimit))
                        .tint(.purple)
                        .scaleEffect(y: 1.4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.black)
    }
}

// ---------------------------------------------------------------------------
// Medium widget
// ---------------------------------------------------------------------------

private struct MediumView: View {
    let entry: UsageEntry

    var body: some View {
        HStack(spacing: 0) {
            // Left: usage counter
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.purple)
                    Text("Tono")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.purple)
                }
                Spacer()
                if entry.isPro {
                    Text("∞")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("unlimited")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Text("\(entry.used)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("of \(entry.displayLimit)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    if entry.displayLimit > 0 {
                        ProgressView(value: Double(entry.used), total: Double(entry.displayLimit))
                            .tint(.purple)
                            .scaleEffect(y: 1.4)
                            .frame(width: 60)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .leading)
            .padding(14)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 14)

            // Right: last rewrite perception
            VStack(alignment: .leading, spacing: 6) {
                if let perception = entry.lastPerception {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(riskColor(entry.lastRiskLevel))
                            .frame(width: 6, height: 6)
                        Text("Last result")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Text(perception)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: "keyboard")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.15))
                    Text("Coach a draft to see your last result here.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        }
        .background(Color.black)
    }
}

// ---------------------------------------------------------------------------
// Lock screen accessory widget (.accessoryRectangular)
// ---------------------------------------------------------------------------

private struct AccessoryView: View {
    let entry: UsageEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
            if entry.isPro {
                Text("Tono · Pro ∞")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            } else {
                Text("Tono · \(entry.used)/\(entry.displayLimit) rewrites")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            Spacer()
        }
        .widgetAccentable()
    }
}

// ---------------------------------------------------------------------------
// Entry view dispatcher
// ---------------------------------------------------------------------------

struct TonoWidgetEntryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallView(entry: entry)
        case .systemMedium:
            MediumView(entry: entry)
        case .accessoryRectangular:
            AccessoryView(entry: entry)
        default:
            SmallView(entry: entry)
        }
    }
}

// ---------------------------------------------------------------------------
// Widget configuration
// ---------------------------------------------------------------------------

@main
struct TonoWidget: Widget {
    let kind: String = "TonoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            TonoWidgetEntryView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Tono Rewrites")
        .description("Daily rewrite usage and your last tone result.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// ---------------------------------------------------------------------------
// Previews
// ---------------------------------------------------------------------------

#Preview("Small — free", as: .systemSmall) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, used: 4, limit: 10, isPro: false,
               lastPerception: "Might land as guilt-trip. 📩", lastRiskLevel: "high")
    UsageEntry(date: .now, used: 10, limit: 10, isPro: false,
               lastPerception: nil, lastRiskLevel: nil)
}

#Preview("Medium — free", as: .systemMedium) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, used: 3, limit: 10, isPro: false,
               lastPerception: "Lands cleanly. ✅", lastRiskLevel: "low")
}

#Preview("Medium — Pro", as: .systemMedium) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, used: 22, limit: -1, isPro: true,
               lastPerception: "The ask is hard to act on. 🤔", lastRiskLevel: "medium")
}

#Preview("Lock screen", as: .accessoryRectangular) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, used: 4, limit: 10, isPro: false,
               lastPerception: nil, lastRiskLevel: nil)
}

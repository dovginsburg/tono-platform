// TonoWidget.swift
// WidgetKit small / medium / lock-screen widget showing subscription access
// and the most recent analysis result.
//
// Xcode setup:
//   1. File > New > Target > Widget Extension, name "TonoWidget"
//   2. Add App Group "group.com.tonoit.shared" to the widget target
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
    let isPro: Bool
    let lastPerception: String?
    let lastRiskLevel: String?  // "low" | "medium" | "high"
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), isPro: false,
                   lastPerception: "Lands cleanly. ✅", lastRiskLevel: "low")
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        // Refresh hourly to pick up entitlement or analysis changes even if the
        // host app did not trigger an explicit reload.
        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }

    private func currentEntry() -> UsageEntry {
        let d = UserDefaults(suiteName: "group.com.tonoit.shared") ?? .standard
        return UsageEntry(
            date: Date(),
            isPro: d.bool(forKey: "tc.proUnlocked"),
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
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                Text("Pro · active")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.purple)
                Text("subscription required")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
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
            // Left: subscription status
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
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                    Text("Pro active")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.purple)
                    Text("subscription required")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
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
                Text("Tono · Pro active")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            } else {
                Text("Tono · subscription required")
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
        .description("Subscription access and your last tone result.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// ---------------------------------------------------------------------------
// Previews
// ---------------------------------------------------------------------------

#Preview("Small — subscription required", as: .systemSmall) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, isPro: false,
               lastPerception: "Might land as guilt-trip. 📩", lastRiskLevel: "high")
    UsageEntry(date: .now, isPro: false,
               lastPerception: nil, lastRiskLevel: nil)
}

#Preview("Medium — subscription required", as: .systemMedium) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, isPro: false,
               lastPerception: "Lands cleanly. ✅", lastRiskLevel: "low")
}

#Preview("Medium — Pro", as: .systemMedium) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, isPro: true,
               lastPerception: "The ask is hard to act on. 🤔", lastRiskLevel: "medium")
}

#Preview("Lock screen", as: .accessoryRectangular) {
    TonoWidget()
} timeline: {
    UsageEntry(date: .now, isPro: false,
               lastPerception: nil, lastRiskLevel: nil)
}

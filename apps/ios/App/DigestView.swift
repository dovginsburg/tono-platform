// DigestView.swift
// Weekly coaching report — rewrites, days active, top axis, axis trends vs prior week.
// Free users see the top-line stats (rewrites, days, go-to axis) with real data.
// Depth features (axis breakdown bars, trends, streak card) are Pro-only.

import SwiftUI

struct DigestView: View {
    @ObservedObject private var store = StoreKitManager.shared
    @State private var digest: WeeklyDigestResponse?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPaywall = false

    // Presentation reads the canonical tri-state authority (build 91 §7); the
    // cached `proUnlocked` Bool is never consulted for gating.
    private var isPro: Bool { store.isPro || TonePreferences().isProAuthoritative }

    // Build 115 — read so the axis rows can stop being a row when the words
    // no longer fit beside each other. See `axisRow`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .tonoGlyphFont(size: 32, relativeTo: .largeTitle)
                            .foregroundColor(.yellow)
                        Text(err)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let d = digest {
                    digestContent(d)
                }
            }
            .navigationTitle("This week")
            .navigationBarTitleDisplayMode(.large)
            .task { await load() }
            .sheet(isPresented: $showPaywall) {
                PaywallView(onDismiss: { showPaywall = false })
            }
        }
    }

    // MARK: - Content

    private func digestContent(_ d: WeeklyDigestResponse) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Top-line stats — visible to all users (real data, no blur)
                HStack(spacing: 16) {
                    StatTile(value: "\(d.rewrites)", label: "Rewrites")
                    StatTile(value: "\(d.daysActive)", label: "Active days")
                }

                if let top = d.topAxis {
                    VStack(spacing: 6) {
                        Text("Your go-to this week")
                            .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(top.capitalized)
                            .tonoFont(size: 28, weight: .bold, relativeTo: .title)
                            .foregroundColor(.purple)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if d.rewrites == 0 {
                    Text("No rewrites this week yet — tap Coach on any draft to get started.")
                        .tonoFont(size: 14, relativeTo: .subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Depth features — Pro only
                if isPro {
                    // Build 115 — iPad. The breakdown and the streak are peer
                    // depth cards about the same week, so where there is room
                    // they sit beside each other rather than pushing the second
                    // one below the fold. `spacing: 20` is the spacing of the
                    // stack they were direct children of, so at a phone width
                    // this is frame-for-frame what shipped.
                    AdaptiveItemGrid(minimumItemWidth: 300, spacing: 20, maximumColumns: 2) {
                        if !d.axisBreakdown.isEmpty {
                            axisBars(d.axisBreakdown, prevBreakdown: d.prevAxisBreakdown)
                        }
                        if d.daysActive >= 5 {
                            streakCard(days: d.daysActive)
                        }
                    }
                } else {
                    DigestDepthTeaser(onUpgrade: { showPaywall = true })
                }
            }
            .padding(20)
            // Build 115 — iPad. A weekly report is a reading surface: the
            // tiles, the go-to card and the depth cards all belong to one
            // column that stops growing at a readable measure.
            .tonoReadableColumn(.reading)
        }
    }

    private func axisBars(_ counts: [String: Int], prevBreakdown: [String: Int]) -> some View {
        let sorted = counts.sorted { $0.value > $1.value }
        let maxCount = sorted.first?.value ?? 1
        let prevTotal = prevBreakdown.values.reduce(0, +)
        let currTotal = counts.values.reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Axis breakdown")
                .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundColor(.secondary)

            ForEach(sorted, id: \.key) { axis, count in
                VStack(alignment: .leading, spacing: 4) {
                    axisRow(axis: axis, count: count, maxCount: maxCount)
                    if let trendText = weekOverWeekTrend(
                        axis: axis, currCount: count, currTotal: currTotal,
                        prevBreakdown: prevBreakdown, prevTotal: prevTotal
                    ) {
                        Text(trendText)
                            .tonoFont(size: 11, relativeTo: .caption2)
                            .foregroundColor(.secondary)
                            // Tracks the label gutter, so the trend keeps
                            // hanging under the bar rather than under the word.
                            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 74)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // Build 115 — iPad. Beside the streak card, the breakdown must stay one
        // stop rather than interleaving with it row by row.
        .accessibilityElement(children: .contain)
    }

    /// One axis: its name, its bar, its count.
    ///
    /// Build 115 — the shipped row put the name in a fixed 64pt gutter and the
    /// count in a fixed 28pt one. Those are the right numbers at the default
    /// text size and they clip the moment a person turns text up, so at
    /// accessibility sizes the row stops being a row: the words get the full
    /// width and the bar sits under them. Nothing is dropped either way.
    @ViewBuilder
    private func axisRow(axis: String, count: Int, maxCount: Int) -> some View {
        let bar = GeometryReader { geo in
            Capsule()
                .fill(Color.purple.opacity(0.3))
                .frame(width: geo.size.width * CGFloat(count) / CGFloat(maxCount), height: 12)
                .frame(maxHeight: .infinity)
        }
        .frame(height: 12)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(axis.capitalized)
                        .tonoFont(size: 14, relativeTo: .subheadline)
                    Spacer(minLength: 8)
                    Text("\(count)")
                        .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                        .foregroundColor(.secondary)
                }
                bar
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                Text(axis.capitalized)
                    .tonoFont(size: 14, relativeTo: .subheadline)
                    .frame(width: 64, alignment: .leading)
                bar
                Text("\(count)")
                    .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }

    /// Returns a human-readable trend string if there's meaningful week-over-week movement.
    private func weekOverWeekTrend(
        axis: String,
        currCount: Int,
        currTotal: Int,
        prevBreakdown: [String: Int],
        prevTotal: Int
    ) -> String? {
        guard currTotal > 0, prevTotal > 0 else { return nil }
        let currPct = Double(currCount) / Double(currTotal)
        let prevPct = Double(prevBreakdown[axis] ?? 0) / Double(prevTotal)
        let delta = currPct - prevPct
        guard abs(delta) >= 0.05 else { return nil }  // ignore sub-5pp swings
        let pct = Int(abs(delta * 100).rounded())
        return delta > 0
            ? "\(pct)% more often than last week"
            : "\(pct)% less than last week"
    }

    private func streakCard(days: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flame.fill")
                .tonoGlyphFont(size: 24, relativeTo: .title2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(days)-day coaching streak")
                    .tonoFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                Text("Consistent practice is where the improvement compounds.")
                    .tonoFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            digest = try await TonoBackend.shared.weeklyDigest()
        } catch {
            // Build 112: the failure's own text names transports and status
            // codes. This Week shows what the user can do instead.
            errorMessage = ConsumerErrorCopy.message(for: error, action: .weeklySummary)
        }
        isLoading = false
    }
}

// MARK: - Pro depth teaser (shown inline below free stats)

private struct DigestDepthTeaser: View {
    let onUpgrade: () -> Void

    private let exampleRows: [(axis: String, trend: String)] = [
        ("Warmer",  "↑ 18% vs last week"),
        ("Clearer", "—"),
        ("Safer",   "↓ 7% vs last week"),
        ("Funnier", "—"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Blurred axis breakdown example
            VStack(alignment: .leading, spacing: 8) {
                Text("Axis breakdown & trends")
                    .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.secondary)
                ForEach(exampleRows, id: \.axis) { row in
                    HStack {
                        Text(row.axis)
                            .tonoFont(size: 14, relativeTo: .subheadline)
                            .frame(width: 70, alignment: .leading)
                        Capsule()
                            .fill(Color.purple.opacity(0.3))
                            .frame(height: 10)
                        Spacer()
                        Text(row.trend)
                            .tonoFont(size: 12, relativeTo: .caption)
                            .foregroundColor(row.trend.hasPrefix("↑") ? .green : row.trend.hasPrefix("↓") ? .orange : .secondary)
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .blur(radius: 3)

            Button(action: onUpgrade) {
                Text("Unlock axis trends & streak tracking →")
                    .tonoFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            // The one action under the teaser. It takes the narrower form
            // measure so it stays a button instead of becoming a bar across
            // the reading column.
            .tonoReadableColumn(.form)
        }
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .tonoFont(size: 36, weight: .bold, relativeTo: .largeTitle)
                .foregroundColor(.primary)
            Text(label)
                .tonoFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

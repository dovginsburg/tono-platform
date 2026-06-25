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

    private var isPro: Bool { store.isPro || TonePreferences().proUnlocked }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
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
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(top.capitalized)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.purple)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if d.rewrites == 0 {
                    Text("No rewrites this week yet — tap Coach on any draft to get started.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                // Depth features — Pro only
                if isPro {
                    if !d.axisBreakdown.isEmpty {
                        axisBars(d.axisBreakdown, prevBreakdown: d.prevAxisBreakdown)
                    }

                    if d.daysActive >= 5 {
                        streakCard(days: d.daysActive)
                    }
                } else {
                    DigestDepthTeaser(onUpgrade: { showPaywall = true })
                }
            }
            .padding(20)
        }
    }

    private func axisBars(_ counts: [String: Int], prevBreakdown: [String: Int]) -> some View {
        let sorted = counts.sorted { $0.value > $1.value }
        let maxCount = sorted.first?.value ?? 1
        let prevTotal = prevBreakdown.values.reduce(0, +)
        let currTotal = counts.values.reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Axis breakdown")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)

            ForEach(sorted, id: \.key) { axis, count in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(axis.capitalized)
                            .font(.system(size: 14, design: .rounded))
                            .frame(width: 64, alignment: .leading)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.purple.opacity(0.3))
                                .frame(width: geo.size.width * CGFloat(count) / CGFloat(maxCount), height: 12)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 12)
                        Text("\(count)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                    if let trendText = weekOverWeekTrend(
                        axis: axis, currCount: count, currTotal: currTotal,
                        prevBreakdown: prevBreakdown, prevTotal: prevTotal
                    ) {
                        Text(trendText)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.leading, 74)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                .font(.system(size: 24))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(days)-day coaching streak")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Consistent practice is where the improvement compounds.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            digest = try await TonoBackend.shared.weeklyDigest()
        } catch {
            errorMessage = error.localizedDescription
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                ForEach(exampleRows, id: \.axis) { row in
                    HStack {
                        Text(row.axis)
                            .font(.system(size: 14, design: .rounded))
                            .frame(width: 70, alignment: .leading)
                        Capsule()
                            .fill(Color.purple.opacity(0.3))
                            .frame(height: 10)
                        Spacer()
                        Text(row.trend)
                            .font(.system(size: 12, design: .rounded))
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
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
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
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MemoryView.swift
// Browse, add, and delete the on-device memory facts Tono infers from
// usage patterns. Facts are sent as short context hints with each rewrite
// request so the LLM personalizes results over time.
// Pro-only: free users see a teaser with example facts.

import SwiftUI

struct MemoryView: View {
    @ObservedObject private var store = StoreKitManager.shared
    @State private var facts: [MemoryFact] = []
    @State private var showAddSheet = false
    @State private var showClearConfirm = false
    @State private var showPaywall = false

    // Presentation reads the canonical tri-state authority (build 91 §7); the
    // cached `proUnlocked` Bool is never consulted for gating.
    private var isPro: Bool { store.isPro || TonePreferences().isProAuthoritative }

    var body: some View {
        Group {
            if isPro {
                List {
                    if facts.isEmpty {
                        emptyStateSection
                    } else {
                        howItWorksSection
                        ForEach(MemoryFact.Category.allCases, id: \.self) { category in
                            let catFacts = facts.filter { $0.category == category }
                            if !catFacts.isEmpty {
                                Section(category.rawValue) {
                                    ForEach(catFacts) { fact in
                                        FactRow(fact: fact)
                                            .swipeActions(edge: .trailing) {
                                                Button(role: .destructive) {
                                                    UserMemory.remove(id: fact.id)
                                                    facts = UserMemory.allFacts()
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showAddSheet = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                    if !facts.isEmpty {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Clear all") { showClearConfirm = true }
                                .foregroundColor(.red)
                                // Declared in `TonoTextStyle.memoryClearAll`,
                                // which carries `face: .standard` because this
                                // button shipped `.font(.system(size: 14))`
                                // with no `design:` argument, i.e. SF Pro. Only
                                // the Dynamic Type scaling is new; the typeface
                                // is the one that was approved.
                                .tonoFont(.memoryClearAll)
                        }
                    }
                }
                // Build 115 — iPad. A grouped list of short facts running the
                // full 1,032pt of an iPad is a line of text with a quarter-mile
                // of empty space after it. The list keeps its own full-bleed
                // background and its CONTENT takes a readable measure.
                .tonoReadableColumn(.reading)
                .background(Color(.systemGroupedBackground))
                .onAppear { facts = UserMemory.allFacts() }
                .sheet(isPresented: $showAddSheet) {
                    AddMemoryFactView { content, category in
                        UserMemory.addManual(content: content, category: category)
                        facts = UserMemory.allFacts()
                    }
                }
                .confirmationDialog(
                    "Clear all memories?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear all", role: .destructive) {
                        UserMemory.removeAll()
                        facts = UserMemory.allFacts()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Tono will start learning again from your next session.")
                }
            } else {
                MemoryProTeaser(onUpgrade: { showPaywall = true })
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView(onDismiss: { showPaywall = false })
        }
    }

    // MARK: - Sections

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "brain")
                    .tonoGlyphFont(size: 40, relativeTo: .largeTitle)
                    .foregroundColor(.secondary)
                Text("No memories yet")
                    .tonoFont(size: 17, weight: .semibold, relativeTo: .body)
                Text("Tono learns from your rewrite choices. After a few sessions, it will recognize patterns here and use them to personalize future rewrites automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add something manually") { showAddSheet = true }
                    .tonoFont(size: 14, relativeTo: .subheadline)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var howItWorksSection: some View {
        Section {
            Text("These facts are sent as short hints with each rewrite request. Tono uses them to personalize suggestions without you having to repeat yourself.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Pro teaser (shown to free users)

private struct MemoryProTeaser: View {
    let onUpgrade: () -> Void

    private let exampleFacts: [(icon: String, text: String)] = [
        ("sparkles",      "Goes warmer with close colleagues"),
        ("sparkles",      "Direct tone with managers"),
        ("person.2.fill", "Clients prefer formal language"),
        ("sparkles",      "Tends to soften risk before sending"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "brain")
                        .tonoGlyphFont(size: 40, relativeTo: .largeTitle)
                        .foregroundColor(.purple)
                    Text("Tono learns how you communicate")
                        .tonoFont(size: 20, weight: .bold, relativeTo: .title3)
                        .multilineTextAlignment(.center)
                    Text("After a few sessions, Tono builds a picture of how you write — and quietly adjusts rewrites to sound like you at your best.")
                        .tonoFont(size: 14, relativeTo: .subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Example — what Pro subscribers see")
                        .tonoFont(size: 11, weight: .semibold, relativeTo: .caption2)
                        .foregroundColor(.secondary)
                    ForEach(exampleFacts, id: \.text) { fact in
                        HStack(spacing: 10) {
                            Image(systemName: fact.icon)
                                .tonoGlyphFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.purple)
                                .frame(width: 18)
                            Text(fact.text)
                                .tonoFont(size: 14, relativeTo: .subheadline)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .blur(radius: 3)

                Button(action: onUpgrade) {
                    Text("Unlock memory →")
                        .tonoFont(size: 16, weight: .semibold, relativeTo: .callout)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                // The one action on this screen. A call to action stretched to
                // a reading measure stops reading as a button, so it keeps the
                // narrower form measure inside the wider column.
                .tonoReadableColumn(.form)
            }
            .padding(24)
            .tonoReadableColumn(.reading)
        }
    }
}

// MARK: - FactRow

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(fact.content)
                .tonoFont(size: 14, relativeTo: .subheadline)
            HStack(spacing: 6) {
                if fact.source == .inferred {
                    Label("Learned", systemImage: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.purple)
                } else {
                    Label("You added this", systemImage: "person.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if fact.useCount > 1 {
                    Text("· confirmed \(fact.useCount)×")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - AddMemoryFactView

private struct AddMemoryFactView: View {
    let onSave: (String, MemoryFact.Category) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var category: MemoryFact.Category = .profile

    private let examples = [
        "I'm a lawyer",
        "I manage a team of 8",
        "I tend to be too blunt",
        "I work in finance",
        "I prefer a direct, no-fluff tone",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("What should Tono remember?") {
                    TextField(
                        "e.g. \(examples.randomElement() ?? examples[0])",
                        text: $content,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(MemoryFact.Category.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("Stored only on this device. Used as a short hint alongside your draft, and never kept afterwards.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tonoReadableColumn(.form)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Add Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(content, category)
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

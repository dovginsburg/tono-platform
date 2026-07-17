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
                                .font(.system(size: 14))
                        }
                    }
                }
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
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No memories yet")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Tono learns from your rewrite choices. After a few sessions, it will recognize patterns here and use them to personalize future rewrites automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add something manually") { showAddSheet = true }
                    .font(.system(size: 14, design: .rounded))
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
                        .font(.system(size: 40))
                        .foregroundColor(.purple)
                    Text("Tono learns how you communicate")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("After a few sessions, Tono builds a picture of how you write — and quietly adjusts rewrites to sound like you at your best.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Example — what Pro subscribers see")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                    ForEach(exampleFacts, id: \.text) { fact in
                        HStack(spacing: 10) {
                            Image(systemName: fact.icon)
                                .font(.system(size: 12))
                                .foregroundColor(.purple)
                                .frame(width: 18)
                            Text(fact.text)
                                .font(.system(size: 14, design: .rounded))
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
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(24)
        }
    }
}

// MARK: - FactRow

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(fact.content)
                .font(.system(size: 14, design: .rounded))
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
                    Text("Stored only on your device. Sent as a short hint alongside your draft — never stored on the server.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
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

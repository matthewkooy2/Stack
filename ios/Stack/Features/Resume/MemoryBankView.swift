import SwiftUI

/// A personal library of work, skills, projects and other resume facts.
@MainActor
struct MemoryBankView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var data: JSON = [:]
    @State private var loaded = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""
    @State private var editing = false
    @State private var editingID = ""
    @State private var revision = 0
    @State private var name = ""
    @State private var source = ""
    private struct Fact: Identifiable {
        let id = UUID()
        var text = ""
    }
    @State private var facts: [Fact] = [Fact()]
    @FocusState private var focusedFact: UUID?
    @State private var deleting: JSON?

    private var sources: [JSON] { data["sources"].array }

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BackButton(label: editing ? "Back to memory bank" : "Close") {
                            if editing { withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = false } }
                            else { dismiss() }
                        }
                        Spacer()
                    }.padding(.bottom, 32)
                    Text(editing ? (editingID.isEmpty ? "Add to memory" : "Edit memory") : "Your memory bank")
                        .font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink).reveal(0)
                    if !editing {
                        Text("Keep your skills, projects and experience in one place.")
                            .font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 10)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        if !loaded { ProgressView().tint(Brand.muted) }
                        MessageLine(text: error).fadeSwitch(!error.isEmpty)
                        MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
                        if editing { editor } else { library }
                    }.padding(.top, 28).reveal(1)
                }
                .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 2) {
                    if editing {
                        StackButton(label: working ? "Saving…" : "Save and confirm", disabled: working || name.isBlank || source.isBlank || facts.allSatisfy { $0.text.isBlank }) {
                            Task { await save(confirm: true) }
                        }
                        Button("Save draft") { Task { await save(confirm: false) } }
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(working || name.isBlank || source.isBlank || facts.allSatisfy { $0.text.isBlank })
                    } else {
                        StackButton(label: "Add to memory") { clear(); withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = true } }
                    }
                }.padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 8).background(Brand.page)
            }
        }
        .replayable()
        .task { await load() }
        .confirmationDialog("Delete this memory and its correction history?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete memory", role: .destructive) { if let item = deleting { Task { await remove(item) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loaded && sources.isEmpty {
                Text("Add skills, projects, work or anything else you want to remember.")
                    .font(Typeface.body).foregroundStyle(Brand.muted).padding(.vertical, 12)
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item["name"].string).font(.system(size: 21, weight: .semibold)).tracking(-0.5).foregroundStyle(Brand.ink)
                        Spacer()
                        if item["editable"].bool {
                            Button("Edit") { edit(item) }
                                .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                                .frame(minWidth: 44, minHeight: 44)
                            Menu {
                                Button("Delete", role: .destructive) { deleting = item }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(Brand.muted).frame(width: 44, height: 44)
                            }.accessibilityLabel("Options for \(item["name"].string)")
                        }
                    }
                    Text(item["confirmed"].bool ? item["source"].string : "Draft · " + item["source"].string)
                        .font(Typeface.caption).foregroundStyle(Brand.muted)
                    ForEach(Array(item["records"].array.enumerated()), id: \.offset) { _, record in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").accessibilityHidden(true)
                            Text(record["text"].string).fixedSize(horizontal: false, vertical: true)
                        }.font(Typeface.body).foregroundStyle(Brand.ink)
                    }
                    if !item["editable"].bool {
                        Text("Edit imported facts in resume details.").font(Typeface.caption).foregroundStyle(Brand.muted)
                    } else if !item["history"].array.isEmpty {
                        DisclosureGroup("Source history") {
                            ForEach(Array(item["history"].array.enumerated()), id: \.offset) { _, entry in
                                Text(entry["source"].string + " · " + entry["records"].array.map { $0["text"].string }.joined(separator: "; "))
                                    .font(Typeface.caption).foregroundStyle(Brand.muted).padding(.vertical, 4)
                            }
                        }.font(Typeface.caption).foregroundStyle(Brand.muted)
                    }
                }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            StackField(label: "Name", text: $name, placeholder: "Work, project, skill or other")
            StackField(label: "Source", text: $source, placeholder: "Where these details came from")
            VStack(alignment: .leading, spacing: 10) {
                Text("Facts").font(Typeface.section).foregroundStyle(Brand.ink)
                ForEach($facts) { $fact in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Typeface.body).padding(.top, 13).accessibilityHidden(true)
                        TextField("Add a detail", text: $fact.text, axis: .vertical)
                            .font(Typeface.body).lineLimit(1...6).focused($focusedFact, equals: fact.id)
                            .padding(.vertical, 13).accessibilityLabel("Fact")
                        Button {
                            focusedFact = nil
                            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) {
                                if facts.count == 1 { facts[0].text = "" } else { facts.removeAll { $0.id == fact.id } }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted.opacity(0.6))
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("Remove fact")
                    }.padding(.leading, 14).background(.white, in: RoundedRectangle(cornerRadius: 14))
                }
                Button {
                    let newFact = Fact()
                    withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { facts.append(newFact) }
                    focusedFact = newFact.id
                } label: {
                    Label("Add fact", systemImage: "plus").font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(Brand.accent).frame(minHeight: 44)
                }
            }
        }
    }

    private func clear() { editingID = ""; revision = 0; name = ""; source = ""; facts = [Fact()]; focusedFact = nil; error = ""; notice = "" }
    private func edit(_ item: JSON) {
        editingID = item["id"].string; revision = item["revision"].int; name = item["name"].string
        source = item["source"].string; facts = item["records"].array.map { Fact(text: $0["text"].string) }; if facts.isEmpty { facts = [Fact()] }
        error = ""; notice = ""
        withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = true }
    }
    private func load() async {
        do { data = try await store.call("resume_bank") }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        loaded = true
    }
    private func save(confirm: Bool) async {
        guard !working else { return }; working = true; error = ""; notice = ""; defer { working = false }
        let lines = facts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let records: [JSON] = lines.enumerated().map { index, line in ["id": .string("r\(index)"), "kind": "bullet", "text": .string(line)] }
        do {
            data = try await store.call("resume_bank_save", ["id": .string(editingID), "revision": .number(Double(revision)), "name": .string(name), "source": .string(source), "records": .array(records), "confirm": .bool(confirm)])
            clear(); notice = confirm ? "Memory saved." : "Draft saved."
            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = false }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    private func remove(_ item: JSON) async {
        guard !working else { return }; working = true; error = ""; defer { working = false }
        do { data = try await store.call("resume_bank_delete", ["id": item["id"], "revision": item["revision"]]) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

import SwiftUI

/// A personal library of work, skills, projects and other resume entries.
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
    @State private var choosing = false
    @State private var target = ""
    @State private var selection: [JSON] = []

    private var sources: [JSON] { data["sources"].array }
    private var confirmedResumes: [JSON] { data["resumes"].array.filter { $0["confirmed"].bool } }

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BackButton(label: editing || choosing ? "Back to experience" : "Close") {
                            if editing { withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = false } }
                            else if choosing { choosing = false; notice = "" }
                            else { dismiss() }
                        }.disabled(working)
                        Spacer()
                    }.padding(.bottom, 16)
                    Text(editing ? (editingID.isEmpty ? "Add entry" : "Edit entry") : choosing ? "Choose entries" : "Experience")
                        .font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink).reveal(0)
                    if choosing {
                        Text("Pick entries to add to a resume").font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 10)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        if !loaded { VStack(spacing: 10) { SkeletonBlock(height: 96, radius: Radius.card); SkeletonBlock(height: 96, radius: Radius.card) } }
                        MessageLine(text: error).fadeSwitch(!error.isEmpty)
                        MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
                        if editing { editor } else {
                            if choosing { resumePicker }
                            library
                        }
                    }.padding(.top, 28).reveal(1)
                }
                .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 2) {
                    if editing {
                        StackButton(label: working ? "Saving…" : "Save", disabled: working || name.isBlank || source.isBlank || facts.allSatisfy { $0.text.isBlank }) {
                            Task { await save(confirm: true) }
                        }
                        Button("Save as draft") { Task { await save(confirm: false) } }
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(working || name.isBlank || source.isBlank || facts.allSatisfy { $0.text.isBlank })
                    } else if choosing {
                        StackButton(label: working ? "Saving…" : "Save choices", disabled: working || target.isEmpty) {
                            Task { await apply() }
                        }.accessibilityIdentifier("memory-save-choices")
                        Button("Clear choices") { selection = []; notice = "Save to use only the resume's own entries" }
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(working || target.isEmpty)
                    } else {
                        StackButton(label: "Add entry") { clear(); withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = true } }
                        Button("Choose entries") {
                            choosing = true; error = ""; notice = ""
                            choose(confirmedResumes.first { $0["id"].string == store.account.selectedResumeID } ?? confirmedResumes.first ?? .null)
                        }.font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(!loaded || working)
                    }
                }.pinnedActionBar()
            }
        }
        .replayable()
        .task { await load() }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { Task { await remove(item) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loaded && sources.isEmpty {
                VStack(spacing: 12) {
                    SymbolDisc(systemName: "archivebox", size: 64)
                    Text("No entries yet").font(Typeface.section).foregroundStyle(Brand.ink)
                    Text("Add skills, projects or work").font(Typeface.caption).foregroundStyle(Brand.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { _, item in
                Card(spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(item["name"].string).font(.headline).foregroundStyle(Brand.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !item["confirmed"].bool { StatusPill(text: "Draft", tone: .warning) }
                        if item["editable"].bool && !choosing {
                            Menu {
                                Button { edit(item) } label: { Label("Edit", systemImage: "pencil") }
                                Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(Brand.muted).frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }.accessibilityLabel("Options for \(item["name"].string)")
                        }
                    }
                    if !item["source"].string.isEmpty {
                        Text(item["source"].string).font(.footnote).foregroundStyle(Brand.muted).padding(.top, -6)
                    }
                    ForEach(Array(item["records"].array.enumerated()), id: \.offset) { _, record in
                        if choosing, !target.isEmpty, item["id"].string != target, item["confirmed"].bool {
                            let selected = isSelected(item, record["id"].string)
                            Button { toggle(item, record["id"].string) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? Brand.accent : Brand.muted)
                                    Text(record["text"].string).font(Typeface.body).foregroundStyle(Brand.ink)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use entry: \(record["text"].string)")
                            .accessibilityValue(selected ? "Selected" : "Not selected")
                            .accessibilityIdentifier("memory-fact-\(item["id"].string)-\(record["id"].string)")
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").accessibilityHidden(true)
                                Text(record["text"].string).fixedSize(horizontal: false, vertical: true)
                            }.font(Typeface.body).foregroundStyle(Brand.ink)
                        }
                    }
                    if choosing, selection.contains(where: { $0["id"] == item["id"] && $0["revision"] != item["revision"] }) {
                        Text("Changed. Choose its entries again").font(.footnote).foregroundStyle(Brand.muted)
                    }
                    if !item["editable"].bool {
                        Text("Edit imported entries in resume details").font(.footnote).foregroundStyle(Brand.muted)
                    } else if !item["history"].array.isEmpty {
                        DisclosureGroup("Source history") {
                            ForEach(Array(item["history"].array.enumerated()), id: \.offset) { _, entry in
                                Text(entry["source"].string + " · " + entry["records"].array.map { $0["text"].string }.joined(separator: "; "))
                                    .font(Typeface.caption).foregroundStyle(Brand.muted).padding(.vertical, 4)
                            }
                        }.font(Typeface.caption).foregroundStyle(Brand.muted)
                    }
                }
            }
        }.disabled(working)
    }

    private var resumePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            if confirmedResumes.isEmpty {
                Text("Confirm a resume first").foregroundStyle(Brand.muted)
            }
            SectionHeader(title: "For resume")
            ForEach(confirmedResumes, id: \.self) { resume in
                Button { choose(resume) } label: {
                    HStack {
                        Text(resume["name"].string).multilineTextAlignment(.leading)
                        Spacer()
                        if target == resume["id"].string { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                    }.font(.body.weight(target == resume["id"].string ? .semibold : .regular))
                    .foregroundStyle(Brand.ink).padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }.buttonStyle(.tap(scale: 0.985)).disabled(working)
                    .accessibilityLabel("Choose resume: \(resume["name"].string)")
                    .accessibilityValue(target == resume["id"].string ? "Selected" : "Not selected")
            }
            ForEach(Array(selection.enumerated()), id: \.offset) { _, choice in
                HStack {
                    Text(sources.first { $0["id"] == choice["id"] }?["name"].string ?? "Unavailable entry")
                        .font(Typeface.caption).foregroundStyle(Brand.muted)
                    Spacer()
                    Button("Remove") { selection.removeAll { $0["id"] == choice["id"] }; notice = "" }
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                        .frame(minWidth: 44, minHeight: 44).disabled(working)
                        .accessibilityLabel("Remove chosen entry: \(choice["id"].string)")
                }
            }
        }
    }

    private func choose(_ resume: JSON) {
        target = resume["id"].string
        selection = resume["selection"].array
        notice = ""
    }

    private func isSelected(_ item: JSON, _ recordID: String) -> Bool {
        selection.contains { $0["id"] == item["id"] && $0["revision"] == item["revision"] && $0["record_ids"].strings.contains(recordID) }
    }

    private func toggle(_ item: JSON, _ recordID: String) {
        let previous = selection.first { $0["id"] == item["id"] }
        var ids = previous?["revision"] == item["revision"] ? previous?["record_ids"].strings ?? [] : []
        ids = ids.toggled(recordID)
        selection.removeAll { $0["id"] == item["id"] }
        if !ids.isEmpty { selection.append(["id": item["id"], "revision": item["revision"], "record_ids": .array(ids.map { .string($0) })]) }
        notice = ""
    }

    private func apply() async {
        guard !working, let resume = confirmedResumes.first(where: { $0["id"].string == target }) else { return }
        working = true; error = ""; notice = ""; defer { working = false }
        do {
            data = try await store.call("resume_bank_select", ["id": .string(target), "revision": resume["revision"], "selection": .array(selection)])
            choose(data["resumes"].array.first { $0["id"].string == target } ?? .null)
            try await store.callAccount("bootstrap")
            notice = "Choices saved for this resume."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            StackField(label: "Name", text: $name, placeholder: "Work, project, skill or other")
            StackField(label: "Source", text: $source, placeholder: "Where these details came from")
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Details")
                ForEach($facts) { $fact in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Typeface.body).padding(.top, 13).accessibilityHidden(true)
                        TextField("Add a detail", text: $fact.text, axis: .vertical)
                            .font(Typeface.body).lineLimit(1...6).focused($focusedFact, equals: fact.id)
                            .padding(.vertical, 13).accessibilityLabel("Detail")
                        Button {
                            focusedFact = nil
                            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) {
                                if facts.count == 1 { facts[0].text = "" } else { facts.removeAll { $0.id == fact.id } }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted.opacity(0.6))
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("Remove detail")
                    }.padding(.leading, 14).background(Palette.field, in: RoundedRectangle(cornerRadius: 14))
                }
                Button {
                    let newFact = Fact()
                    withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { facts.append(newFact) }
                    focusedFact = newFact.id
                } label: {
                    Label("Add detail", systemImage: "plus").font(Typeface.caption.weight(.semibold))
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
            clear(); notice = confirm ? "Saved" : "Draft saved"
            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = false }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    private func remove(_ item: JSON) async {
        guard !working else { return }; working = true; error = ""; defer { working = false }
        do { data = try await store.call("resume_bank_delete", ["id": item["id"], "revision": item["revision"]]) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

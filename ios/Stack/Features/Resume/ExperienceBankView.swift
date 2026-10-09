import SwiftUI

/// Experience beyond the current resume. Only facts you confirm can be reused when tailoring.
@MainActor
struct ExperienceBankView: View {
    @Environment(AppStore.self) private var store

    @State private var data: JSON = [:]
    @State private var loaded = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""

    // The experience being added or edited
    @State private var editingID = ""
    @State private var revision = 0
    @State private var name = ""
    @State private var source = ""
    @State private var text = ""

    // Choosing facts for tailoring
    @State private var target = ""
    @State private var selection: [JSON] = []
    @State private var deleting: JSON?

    private var sources: [JSON] { data["sources"].array }
    private var confirmedResumes: [JSON] { data["resumes"].array.filter { $0["confirmed"].bool } }

    var body: some View {
        SheetPage(title: "Experience bank", subtitle: "Keep experience beyond your current resume.") {
            if !loaded { ProgressView().tint(Palette.muted) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            editor
            tailoring
            ForEach(Array(sources.enumerated()), id: \.offset) { _, item in sourceCard(item) }
            Text("Imported headings and other context lines keep their original order to preserve roles, dates and credentials.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
        .task { await load() }
        .confirmationDialog("Delete this experience and its correction history?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete experience", role: .destructive) {
                if let item = deleting { Task { await remove(item) } }
                deleting = nil
            }
        }
    }

    // MARK: Pieces

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingID.isEmpty ? "Add experience" : "Edit experience").font(Typeface.title).foregroundStyle(Palette.ink)
            StackField(label: "Experience name", text: $name, placeholder: "Role, employer or project, dates")
            StackField(label: "Source of these facts", text: $source, placeholder: "My project notes, 2024")
            StackField(label: "Facts, one bullet per line", text: $text, multiline: true)
            Text("Include the role, employer and dates in the experience name. Confirm only accurate facts. Drafts withdraw confirmation; corrections keep sources and history.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Save and confirm facts", disabled: working || name.isBlank || text.isBlank) { Task { await save(confirm: true) } }
            StackButton(label: "Save draft", kind: .secondary, disabled: working || name.isBlank || text.isBlank) { Task { await save(confirm: false) } }
            if !editingID.isEmpty { StackButton(label: "New experience", kind: .secondary, disabled: working) { clear() } }
        }
    }

    private var tailoring: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose experience for tailoring").font(Typeface.title).foregroundStyle(Palette.ink)
            Text("Choose a confirmed PDF/DOCX resume, then select relevant facts. Review the complete generated resume before approving.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if confirmedResumes.isEmpty {
                Text("Confirm a resume's details first to choose facts for it.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            FlowLayout(spacing: 8) {
                ForEach(Array(confirmedResumes.enumerated()), id: \.offset) { _, resume in
                    Chip(label: resume["name"].string, selected: target == resume["id"].string) {
                        target = resume["id"].string
                        selection = resume["selection"].array
                        notice = ""
                    }
                }
            }
            ForEach(Array(selection.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text("Selected source \(item["id"].string) (\(item["record_ids"].array.count) facts)")
                        .font(Typeface.caption).foregroundStyle(Palette.text)
                    Spacer()
                    Chip(label: "Remove") { selection.removeAll { $0["id"] == item["id"] } }
                }
            }
            StackButton(label: "Save selected experience", disabled: working || target.isEmpty) { Task { await apply() } }
            StackButton(label: "Clear selected experience", kind: .secondary, disabled: working || target.isEmpty) {
                selection = []
                notice = "Selection cleared locally. Save selected experience to apply."
            }
        }
    }

    private func sourceCard(_ item: JSON) -> some View {
        let id = item["id"].string
        return Card(spacing: 8) {
            Text(item["name"].string).font(Typeface.option).foregroundStyle(Palette.icon)
            Text("\(item["source"].string) · \(item["confirmed"].bool ? "Confirmed" : "Draft")")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(item["records"].array.enumerated()), id: \.offset) { _, record in
                let rid = record["id"].string
                VStack(alignment: .leading, spacing: 6) {
                    Text(record["text"].string).font(Typeface.body).foregroundStyle(Palette.text)
                    if !target.isEmpty, target != id, item["confirmed"].bool {
                        Chip(label: isSelected(id, rid) ? "Selected" : "Select fact", selected: isSelected(id, rid)) {
                            toggle(item, rid)
                        }
                    }
                }
            }
            if item["editable"].bool {
                HStack(spacing: 8) {
                    Chip(label: "Edit experience") { edit(item) }
                    Chip(label: "Delete experience") { deleting = item }
                }
                if !item["history"].array.isEmpty {
                    Text("Sources and corrections").font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    ForEach(Array(item["history"].array.enumerated()), id: \.offset) { _, entry in
                        Text("Revision \(entry["revision"].int) · \(entry["source"].string) · " + entry["records"].array.map { $0["text"].string }.joined(separator: "; "))
                            .font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }
            } else {
                Text("Edit imported facts with Review details on the Resume tab.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    // MARK: Selection helpers

    private func isSelected(_ sourceID: String, _ recordID: String) -> Bool {
        selection.contains { $0["id"].string == sourceID && $0["record_ids"].strings.contains(recordID) }
    }

    private func toggle(_ item: JSON, _ recordID: String) {
        let sourceID = item["id"].string
        var ids = selection.first { $0["id"].string == sourceID }?["record_ids"].strings ?? []
        ids = ids.toggled(recordID)
        selection.removeAll { $0["id"].string == sourceID }
        if !ids.isEmpty {
            selection.append(["id": .string(sourceID), "revision": item["revision"], "record_ids": .array(ids.map { .string($0) })])
        }
    }

    private func clear() {
        editingID = ""
        revision = 0
        name = ""
        source = ""
        text = ""
    }

    private func edit(_ item: JSON) {
        editingID = item["id"].string
        revision = item["revision"].int
        name = item["name"].string
        source = item["source"].string
        text = item["records"].array.map { $0["text"].string }.joined(separator: "\n")
        notice = ""
    }

    // MARK: Requests

    private func load() async {
        do {
            data = try await store.call("resume_bank")
            let ids = Set(data["resumes"].array.map { $0["id"].string })
            if !target.isEmpty, !ids.contains(target) { target = ""; selection = [] }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        loaded = true
    }

    private func save(confirm: Bool) async {
        guard !working else { return }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let records: [JSON] = lines.enumerated().map { index, line in
            ["id": .string("r\(index)"), "kind": "bullet", "text": .string(line)]
        }
        do {
            data = try await store.call("resume_bank_save", [
                "id": .string(editingID), "revision": .number(Double(revision)), "name": .string(name),
                "source": .string(source), "records": .array(records), "confirm": .bool(confirm),
            ])
            clear()
            notice = confirm ? "Experience confirmed for reuse." : "Draft saved. Confirm facts before reuse."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func remove(_ item: JSON) async {
        guard !working else { return }
        working = true
        error = ""
        defer { working = false }
        do {
            data = try await store.call("resume_bank_delete", ["id": item["id"], "revision": item["revision"]])
            if editingID == item["id"].string { clear() }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func apply() async {
        guard !working else { return }
        guard let resume = confirmedResumes.first(where: { $0["id"].string == target }) else {
            error = "Reload and choose a resume."
            return
        }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        do {
            data = try await store.call("resume_bank_select", [
                "id": .string(target), "revision": resume["revision"], "selection": .array(selection),
            ])
            try await store.callAccount("bootstrap")
            notice = "Selected facts will be included in your next tailoring review."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

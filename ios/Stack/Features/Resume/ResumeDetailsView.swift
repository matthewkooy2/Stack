import SwiftUI

/// Review of what Stack read from a resume. Section review edits the parsed fields; records review
/// (older imports) edits each extracted line. Original uploads stay unchanged.
@MainActor
struct ResumeDetailsView: View {
    let resume: ResumeItem
    var onConfirmed: (() async -> Void)?

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var document: JSON = [:]
    @State private var values: [String: String] = [:]
    @State private var records: [JSON] = []
    @State private var expanded: Set<String> = ["profile"]
    @State private var busy = true
    @State private var error = ""
    @State private var message = ""
    @State private var dirty = false
    @State private var showSource = false
    @State private var remoteDocument: JSON?

    private var sections: [JSON] { document["sections"].array }
    private var recordMode: Bool { sections.isEmpty && !records.isEmpty }
    private var confirmed: Bool { document["confirmed"].bool }

    var body: some View {
        SheetPage(title: "Resume details", subtitle: resume.name) {
            ProcessingStatusView(resumeID: resume.id, kind: "pdf", processing: document["processing"])
            if busy { ProgressView().tint(Palette.muted).accessibilityLabel("Reading resume") }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            if !error.isEmpty, document.object.isEmpty {
                StackButton(label: "Retry parsing", icon: "refresh", kind: .secondary, disabled: busy) { Task { await load(retry: true) } }
            }
            if !document.object.isEmpty {
                HStack {
                    Text(dirty ? "Unsaved changes" : (confirmed ? "Confirmed" : "Needs review"))
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                    Spacer()
                }
                Text("Check every extracted line. Original uploads stay unchanged. Saving a draft withdraws confirmation.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                if let latest = remoteDocument {
                    Text("Resume processing changed this document. Your unsaved edits are preserved; copy them before reloading.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    StackButton(label: "Discard unsaved edits and reload", kind: .secondary, disabled: busy) {
                        populate(latest, preserveDraft: false)
                    }
                }
                ForEach(document["warnings"].strings, id: \.self) { Text($0).font(Typeface.caption).foregroundStyle(Palette.text) }
                if recordMode { recordEditor } else { sectionEditor }
                StackButton(label: showSource ? "Hide extracted text" : "View extracted text", kind: .secondary) {
                    withAnimation(Motion.fadeAnimation) { showSource.toggle() }
                }
                if showSource {
                    Text(document["text"].string).font(Typeface.caption).foregroundStyle(Palette.text).textSelection(.enabled)
                }
                StackButton(label: onConfirmed != nil ? "Confirm and continue tailoring" : "Confirm resume details", icon: "check",
                            disabled: busy || remoteDocument != nil || (confirmed && !dirty && onConfirmed == nil)) {
                    Task { await save(confirm: true) }
                }
                StackButton(label: "Save draft", kind: .secondary, disabled: busy || remoteDocument != nil || !dirty) { Task { await save(confirm: false) } }
                MessageLine(text: message, isError: false).fadeSwitch(!message.isEmpty)
                Text("OpenResume · AGPL-3.0 · Source and license · No warranty")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
        .task { await load(retry: false) }
        .pollsWhileProcessing(["queued", "parsing"].contains(document["processing"]["status"].string))
        .onChange(of: store.account.processing(of: resume.id)["pdf"]["status"].string) { _, status in
            if status == "completed" { Task { await load(retry: false) } }
        }
    }

    // MARK: Editors

    private var sectionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections, id: \.self) { section in
                let key = section["key"].string
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(Motion.fadeAnimation) {
                            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            GlyphView(name: "chevron", size: 14, color: Palette.muted)
                                .rotationEffect(.degrees(expanded.contains(key) ? 90 : 0))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section["label"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                                Text(section["summary"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
                    }
                    .accessibilityLabel(section["label"].string)
                    .accessibilityAddTraits(expanded.contains(key) ? .isSelected : [])
                    if expanded.contains(key) {
                        ForEach(section["fields"].array, id: \.self) { field in
                            let fieldKey = field["key"].string
                            let label = field["label"].string == "Descriptions" ? "Details" : field["label"].string
                            StackField(label: label,
                                       text: Binding(get: { values[fieldKey] ?? "" },
                                                     set: { values[fieldKey] = $0; dirty = true; message = "" }),
                                       placeholder: "Not found", multiline: true)
                        }
                    }
                }
            }
            FlowLayout(spacing: 8) {
                ForEach([("educations", "Add education"), ("workExperiences", "Add experience"), ("projects", "Add project")], id: \.0) { kind, label in
                    Chip(label: label) { addEntry(kind) }
                }
            }
        }
    }

    private var recordEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                Card(spacing: 10) {
                    StackField(label: "Record \(record["id"].string)",
                               text: Binding(get: { records[index]["text"].string },
                                             set: { records[index]["text"] = .string($0); dirty = true; message = "" }),
                               multiline: true)
                    ChoiceChips(options: ["title", "heading", "paragraph", "bullet"],
                                isSelected: { records[index]["kind"].string == $0 },
                                onTap: { records[index]["kind"] = .string($0); dirty = true; message = "" })
                    if records[index]["kind"].string == "bullet" {
                        ToggleRow(label: "Allow model to propose omission",
                                  isOn: Binding(get: { records[index]["allow_omit"].bool },
                                                set: { records[index]["allow_omit"] = .bool($0); dirty = true }))
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func populate(_ result: JSON, preserveDraft: Bool = true) {
        if dirty, preserveDraft {
            if document["revision"] != result["revision"] { remoteDocument = result }
            return
        }
        remoteDocument = nil
        document = result
        var next: [String: String] = [:]
        for section in result["sections"].array {
            for field in section["fields"].array { next[field["key"].string] = field["value"].string }
        }
        values = next
        records = result["records"].array
        dirty = false
    }

    private func load(retry: Bool) async {
        busy = true
        error = ""
        defer { busy = false }
        do {
            if retry { try await store.callAccount("retry_resume_processing", ["id": .string(resume.id), "kind": "pdf"]) }
            populate(try await store.call("agent_extract_resume", ["id": .string(resume.id)], timeout: 45))
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func save(confirm: Bool) async {
        guard !busy else { return }
        busy = true
        error = ""
        message = ""
        defer { busy = false }
        do {
            if recordMode {
                let result = try await store.call("resume_save_records", [
                    "id": .string(resume.id), "revision": document["revision"], "records": .array(records),
                    "confirm": .bool(confirm), "template": document["template"].string.isEmpty ? "classic" : document["template"],
                ])
                document = result
                records = result["records"].array
                dirty = false
                try await store.callAccount("bootstrap")
            } else {
                if dirty || !confirmed || !confirm {
                    let valuesJSON: JSON = .object(values.mapValues { .string($0) })
                    populate(try await store.call("resume_save_details", [
                        "id": .string(resume.id), "revision": document["revision"], "values": valuesJSON, "confirm": .bool(confirm),
                    ]), preserveDraft: false)
                    try await store.callAccount("bootstrap")
                }
            }
            message = confirm ? "Resume details confirmed." : "Draft saved."
            if confirm, let onConfirmed { await onConfirmed() }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func addEntry(_ kind: String) {
        let current = sections.filter { $0["key"].string.hasPrefix(kind + ".") }
        guard let template = current.first else { return }
        guard current.count < 20 else {
            error = "Up to 20 entries per section."
            return
        }
        let index = current.count
        let prefix = "\(kind).\(index)"
        let baseLabel = template["label"].string.components(separatedBy: " 1").first ?? template["label"].string
        let fields: [JSON] = template["fields"].array.map { field in
            let suffix = field["key"].string.split(separator: ".").last.map(String.init) ?? field["key"].string
            return ["key": .string("\(prefix).\(suffix)"), "label": field["label"], "value": ""]
        }
        let added: JSON = ["key": .string(prefix), "label": .string("\(baseLabel) \(index + 1)"), "summary": "New entry", "fields": .array(fields)]
        document["sections"] = .array(sections + [added])
        for field in fields { values[field["key"].string] = "" }
        expanded.insert(prefix)
        dirty = true
    }
}

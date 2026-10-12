import SwiftUI

/// One section of the resume review: contact, skills and the like show their fields; entry sections
/// show each entry with its own actions (move, remove) and an add button.
@MainActor
struct ResumeSectionEditor: View {
    let controller: ResumeReviewController
    let sectionKey: String
    let onBack: () -> Void

    @State private var pendingRemoval: PendingRemoval?

    private struct PendingRemoval: Hashable {
        let section: String
        let id: String
        let title: String
    }

    private var document: ResumeDocument { controller.document }
    private var spec: ResumeSectionSpec? { ResumeSchema.spec(sectionKey) }
    private var isOther: Bool { sectionKey == ResumeReviewController.otherSectionID }
    private var title: String { isOther ? "Other fields" : document.sectionTitle(sectionKey) }
    private var isRepeated: Bool { spec?.repeated ?? !isOther }
    private var addLabel: String { spec?.addLabel ?? "Add entry" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StackButton(label: "All sections", icon: "return", kind: .secondary, disabled: false, action: onBack)
                .accessibilityIdentifier("resume-review-all-sections")
            Text(title).font(Typeface.section).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            if isOther {
                otherFields
            } else if isRepeated {
                entries
            } else {
                singleFields
            }
        }
        .confirmationDialog("Remove \(pendingRemoval?.title ?? "entry")?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove \(pendingRemoval?.title ?? "entry")", role: .destructive) {
                if let pending = pendingRemoval { controller.removeEntry(pending.section, pending.id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This removes the entry and its details from your review. Your original upload is unchanged.")
        }
    }

    // MARK: Single sections

    @ViewBuilder
    private var singleFields: some View {
        if let spec {
            ForEach(controller.fieldSpecs(spec.key), id: \.name) { field in
                ResumeFieldRow(controller: controller, address: .single("\(spec.key).\(field.name)"), label: field.label,
                               accessibleLabel: "\(spec.title) \(field.label)", bullets: field.bullets,
                               multiline: field.multiline, email: field.email)
            }
            ForEach(document.extraKeys(in: spec.key).filter { key in
                !controller.fieldSpecs(spec.key).contains { "\(spec.key).\($0.name)" == key }
            }, id: \.self) { key in
                ResumeFieldRow(controller: controller, address: .single(key), label: document.label(forKey: key),
                               accessibleLabel: "\(spec.title) \(document.label(forKey: key))",
                               bullets: key.hasSuffix(".descriptions"))
            }
        }
    }

    private var otherFields: some View {
        ForEach(document.strayKeys, id: \.self) { key in
            ResumeFieldRow(controller: controller, address: .single(key), label: document.label(forKey: key),
                           accessibleLabel: "Other \(document.label(forKey: key))", bullets: key.hasSuffix(".descriptions"))
        }
    }

    // MARK: Entry sections

    private var entries: some View {
        let list = document.entries(of: sectionKey)
        let entryLabel = spec?.entryLabel ?? title
        return VStack(alignment: .leading, spacing: 16) {
            if list.isEmpty {
                Text("Nothing here yet. Add an entry to fill in its details.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                entryCard(entry, index: index, count: list.count, label: "\(entryLabel) \(index + 1)")
            }
            StackButton(label: addLabel, icon: "add-session", kind: .primary,
                        disabled: !controller.canEdit || !controller.canAddEntry(sectionKey)) {
                controller.addEntry(sectionKey)
            }
            .accessibilityIdentifier("resume-review-add-\(sectionKey)")
            MessageLine(text: controller.error).fadeSwitch(!controller.error.isEmpty)
        }
    }

    private func entryCard(_ entry: ResumeEntry, index: Int, count: Int, label: String) -> some View {
        let known = controller.fieldSpecs(sectionKey)
        let knownNames = Set(known.map(\.name))
        let extras = entry.values.keys.filter { !knownNames.contains($0) }.sorted()
        return Card(spacing: 14) {
            HStack {
                Text(label).font(Typeface.option).foregroundStyle(Palette.icon).accessibilityAddTraits(.isHeader)
                if document.isChanged(sectionKey, entry.id) {
                    Text("Edited").font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                }
                Spacer()
                Menu {
                    Button("Move up") { controller.moveEntry(sectionKey, entry.id, by: -1) }.disabled(index == 0)
                    Button("Move down") { controller.moveEntry(sectionKey, entry.id, by: 1) }.disabled(index == count - 1)
                    Button("Remove entry", role: .destructive) {
                        pendingRemoval = PendingRemoval(section: sectionKey, id: entry.id, title: label)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(!controller.canEdit)
                .accessibilityLabel("Actions for \(label)")
                .accessibilityIdentifier("resume-review-entry-actions-\(sectionKey)-\(index)")
            }
            ForEach(known, id: \.name) { field in
                ResumeFieldRow(controller: controller, address: .entry(section: sectionKey, id: entry.id, field: field.name),
                               label: field.label, accessibleLabel: "\(label) \(field.label)", bullets: field.bullets,
                               multiline: field.multiline)
            }
            ForEach(extras, id: \.self) { name in
                let fieldLabel = document.label(section: sectionKey, field: name)
                ResumeFieldRow(controller: controller, address: .entry(section: sectionKey, id: entry.id, field: name),
                               label: fieldLabel, accessibleLabel: "\(label) \(fieldLabel)", bullets: name == "descriptions")
            }
        }
    }
}

/// A labelled text field. Once edited it shows the last saved value and a way back to it; the original
/// extraction is a separate read-only screen because entries are renumbered and reordered by saving.
@MainActor
struct ResumeFieldRow: View {
    let controller: ResumeReviewController
    let address: ResumeFieldAddress
    let label: String
    let accessibleLabel: String
    var bullets = false
    var multiline = false
    var email = false

    private var changed: Bool { controller.document.isChanged(at: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if bullets {
                ResumeBulletEditor(controller: controller, address: address, label: label, accessibleLabel: accessibleLabel)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(label).font(Typeface.caption).foregroundStyle(Palette.muted)
                    TextField("Not found", text: Binding(get: { controller.document.value(at: address) },
                                                         set: { controller.set($0, at: address) }),
                              axis: multiline ? .vertical : .horizontal)
                        .lineLimit(multiline ? 3...10 : 1...3)
                        .font(Typeface.body)
                        .foregroundStyle(Palette.text)
                        .keyboardType(email ? .emailAddress : .default)
                        .textInputAutocapitalization(email ? .never : .sentences)
                        .autocorrectionDisabled(email)
                        .disabled(!controller.canEdit)
                        .accessibilityLabel(accessibleLabel)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(minHeight: 54, alignment: .topLeading)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
                }
            }
            if let problem = controller.problem(at: address) {
                Text(problem).font(Typeface.caption).foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("resume-problem-\(accessibleLabel)")
            }
            if changed {
                let saved = controller.document.saved(at: address)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(saved.isEmpty ? "Last saved: empty" : "Last saved: \(saved.replacingOccurrences(of: "\n", with: " · "))")
                        .font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(3)
                        .accessibilityIdentifier("resume-saved-\(accessibleLabel)")
                    Spacer(minLength: 0)
                    Button("Undo change") { controller.revert(at: address) }
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                        .frame(minHeight: 44)
                        .disabled(!controller.canEdit)
                        .accessibilityLabel("Undo change \(accessibleLabel)")
                }
            }
        }
    }
}

/// A bullet list: each item is its own field, with add, remove and reorder.
@MainActor
struct ResumeBulletEditor: View {
    let controller: ResumeReviewController
    let address: ResumeFieldAddress
    let label: String
    let accessibleLabel: String

    var body: some View {
        let items = controller.bullets(at: address)
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Typeface.caption).foregroundStyle(Palette.muted)
            if items.isEmpty {
                Text("Not found").font(Typeface.body).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
            }
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").font(Typeface.body).foregroundStyle(Palette.muted).padding(.top, 2).accessibilityHidden(true)
                    TextField("Item \(index + 1)", text: Binding(
                        get: { controller.bullets(at: address).indices.contains(index) ? controller.bullets(at: address)[index] : "" },
                        set: { controller.setBullet($0, at: index, of: address) }), axis: .vertical)
                        .lineLimit(1...6)
                        .font(Typeface.body)
                        .foregroundStyle(Palette.text)
                        .disabled(!controller.canEdit)
                        .accessibilityLabel("\(accessibleLabel) item \(index + 1)")
                    Menu {
                        Button("Move up") { controller.moveBullet(at: index, by: -1, of: address) }.disabled(index == 0)
                        Button("Move down") { controller.moveBullet(at: index, by: 1, of: address) }.disabled(index == items.count - 1)
                        Button("Remove item", role: .destructive) { controller.removeBullet(at: index, of: address) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 18)).foregroundStyle(Palette.muted)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .disabled(!controller.canEdit)
                    .accessibilityLabel("Actions for \(accessibleLabel) item \(index + 1)")
                }
                .padding(.leading, 18).padding(.trailing, 2).padding(.vertical, 2)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
            }
            Chip(label: "Add item") { controller.addBullet(to: address) }
                .disabled(!controller.canEdit)
                .accessibilityLabel("Add item to \(accessibleLabel)")
        }
    }
}

/// The original extraction, read-only and in the order it was extracted. Entry numbers are original
/// positions; they are not matched to the current entries, which saving may have reordered.
@MainActor
struct ResumeOriginalScreen: View {
    let controller: ResumeReviewController
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StackButton(label: "All sections", icon: "return", kind: .secondary, disabled: false, action: onBack)
                .accessibilityIdentifier("resume-review-all-sections")
            Text("Original extraction").font(Typeface.section).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Text("Read-only. These are the fields first extracted from your upload, in their original order. "
                 + "They are unaltered by edits or editable-field limits. The accepted source text is below.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(controller.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(Typeface.caption).foregroundStyle(Palette.text)
            }
            let groups = controller.originalGroups
            if controller.originalValues == nil {
                Text("The original fields are not available for this resume.").font(Typeface.caption).foregroundStyle(Palette.muted)
            } else if groups.isEmpty {
                Text("Nothing was extracted.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ForEach(groups) { group in
                Card(spacing: 10) {
                    Text(group.title).font(Typeface.option).foregroundStyle(Palette.icon).accessibilityAddTraits(.isHeader)
                    ForEach(group.fields) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label).font(Typeface.caption).foregroundStyle(Palette.muted)
                            Text(field.value).font(Typeface.body).foregroundStyle(Palette.text).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("resume-original-field-\(field.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("resume-original-group-\(group.id)")
            }
            Text("Extracted text").font(Typeface.option).foregroundStyle(Palette.icon).accessibilityAddTraits(.isHeader)
            Text(controller.sourceText.isEmpty ? "No text was extracted." : controller.sourceText)
                .font(Typeface.caption).foregroundStyle(Palette.text).textSelection(.enabled)
                .accessibilityIdentifier("resume-original-source-text")
        }
    }
}

/// Older imports have extracted lines instead of fields; each line is edited as text.
@MainActor
struct ResumeRecordsEditor: View {
    let controller: ResumeReviewController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(controller.records.enumerated()), id: \.offset) { index, record in
                Card(spacing: 10) {
                    Text("Record \(record["id"].string)").font(Typeface.caption).foregroundStyle(Palette.muted)
                    TextField("Not found", text: Binding(get: { controller.record(index)["text"].string },
                                                         set: { controller.setRecord(index, key: "text", value: .string($0)) }),
                              axis: .vertical)
                        .lineLimit(2...10)
                        .font(Typeface.body)
                        .disabled(!controller.canEditRecords)
                        .accessibilityLabel("Record \(record["id"].string)")
                    ChoiceChips(options: ["title", "heading", "paragraph", "bullet"],
                                isSelected: { controller.record(index)["kind"].string == $0 },
                                onTap: { controller.setRecord(index, key: "kind", value: .string($0)) })
                    if controller.record(index)["kind"].string == "bullet" {
                        ToggleRow(label: "Allow model to propose omission",
                                  isOn: Binding(get: { controller.record(index)["allow_omit"].bool },
                                                set: { controller.setRecord(index, key: "allow_omit", value: .bool($0)) }))
                    }
                }
            }
        }
    }
}

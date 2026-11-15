import SwiftUI

/// Cards retain the original IDs used by the existing approval endpoint.
private struct TailoringSuggestion: Identifiable {
    let value: JSON
    var id: String { value["id"].string }
    var kind: String { value["kind"].string }
    var isOrder: Bool { kind == "order" || kind == "reorder" }
    var before: String { value["before"].string.replacingOccurrences(of: "**", with: "") }
    var after: String { value["after"].string.replacingOccurrences(of: "**", with: "") }
    var reason: String { value["reason"].string.components(separatedBy: "Source:")[0].trimmingCharacters(in: .whitespacesAndNewlines) }
    var location: String {
        let text = value["where"].string
        return text.range(of: "^r[0-9]+$", options: .regularExpression) == nil ? text : ""
    }
    var legacyRecordOrder: Bool {
        isOrder && proposedItems.isEmpty && before.range(of: "^r[0-9]+(, r[0-9]+)*$", options: .regularExpression) != nil
    }
    var isFillerRemoval: Bool {
        ["I ", "Successfully ", "Duties included: "].contains { prefix in
            before.hasPrefix(prefix) && String(before.dropFirst(prefix.count)).lowercased() == after.lowercased()
        }
    }
    var label: String {
        if isOrder { return "BULLET ORDER" }
        if kind == "omit" { return "REMOVE CONTENT" }
        return kind == "add" ? "FROM MEMORY BANK" : "WORDING"
    }
    var title: String {
        if !value["title"].string.isEmpty { return value["title"].string }
        if isOrder { return "Change bullet order" }
        if kind == "omit" { return "Leave this content out" }
        if kind == "add" { return "Add from memory bank" }
        if isFillerRemoval {
            return "Remove introductory filler"
        }
        return "Update wording"
    }
    var originalItems: [JSON] { value["before_items"].array }
    var proposedItems: [JSON] { value["after_items"].array }
}

@MainActor
struct TailoringReviewScreen: View {
    let review: JSON
    let rejected: [String]
    let busy: Bool
    var reviewed: [String] = []
    var error = ""
    var context = ""
    var hasPreview = false
    let onBack: () -> Void
    let onPreview: () -> Void
    let onSetRejected: ([String], Bool) -> Void
    let onApply: () -> Void
    let onCancel: () -> Void

    @State private var showAll = false
    @State private var focusedID: String?
    @State private var showDetails = false
    @State private var showOriginalOrder = false

    private var suggestions: [TailoringSuggestion] { review["changes"].array.map { TailoringSuggestion(value: $0) } }
    private var current: TailoringSuggestion? {
        suggestions.first { $0.id == focusedID }
            ?? suggestions.first { !reviewed.contains($0.id) } ?? suggestions.first
    }
    private var reviewedCount: Int { suggestions.filter { reviewed.contains($0.id) }.count }
    private var complete: Bool { reviewedCount == suggestions.count }
    private var overview: Bool { showAll || suggestions.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                navigation
                heading
                if overview {
                    LazyVStack(spacing: 12) {
                        ForEach(suggestions) { overviewCard($0) }
                    }
                    .padding(.horizontal, -6)
                    if suggestions.isEmpty {
                        Text("No wording or order changes were needed.")
                            .font(Typeface.body).foregroundStyle(Brand.muted)
                    }
                } else if let current { focusedContent(current) }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .id(overview ? "all" : current?.id ?? "empty")
        .scrollIndicators(.hidden)
        .background(Brand.page.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .sheet(isPresented: $showDetails) { details }
        .onChange(of: review["hash"]) { _, _ in
            focusedID = nil
            showOriginalOrder = false
        }
    }

    private var navigation: some View {
        HStack {
            Button {
                if showAll, current != nil { showAll = false } else { onBack() }
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 20)).foregroundStyle(Brand.accent).frame(minHeight: 44)
            }
            Spacer()
            Menu {
                if hasPreview { Button("Preview proposed PDF", action: onPreview) }
                Button("More details") { showDetails = true }
                Button("Cancel tailoring", role: .destructive, action: onCancel)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Brand.muted).frame(width: 44, height: 44)
            }
            .disabled(busy).accessibilityLabel("Tailoring options")
        }
        .buttonStyle(.plain)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RESUME REVIEW").font(.system(size: 13, weight: .semibold))
                .tracking(0.6).foregroundStyle(Brand.muted)
            Text(overview ? "All suggestions." : "One change at a time.")
                .font(.system(size: 36, weight: .heavy)).tracking(-1.8)
                .foregroundStyle(Brand.ink).accessibilityAddTraits(.isHeader)
            if overview {
                Text("\(suggestions.count) suggestions · \(reviewedCount) reviewed")
                    .font(.system(size: 20)).foregroundStyle(Brand.muted)
            } else if let current {
                Text("Suggestion \((suggestions.firstIndex { $0.id == current.id } ?? 0) + 1) of \(suggestions.count)")
                    .font(.system(size: 20)).foregroundStyle(Brand.muted)
                HStack(spacing: 4) {
                    ForEach(suggestions) { suggestion in
                        Capsule().fill(suggestion.id == current.id || reviewed.contains(suggestion.id) ? Brand.accent : Brand.rule)
                            .frame(height: 5)
                    }
                }
                .accessibilityLabel("\(reviewedCount) of \(suggestions.count) suggestions reviewed")
            }
            if !context.isEmpty { Text(context).font(Typeface.body).foregroundStyle(Brand.muted) }
        }
    }

    private func overviewCard(_ suggestion: TailoringSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                badge(suggestion.label, accent: true)
                Spacer()
                badge(reviewed.contains(suggestion.id)
                      ? (rejected.contains(suggestion.id) ? "Original kept" : "Suggestion chosen") : "To review", accent: false)
            }
            Text(suggestion.title).font(.system(size: 20, weight: .bold)).tracking(-0.5).foregroundStyle(Brand.ink)
            if !suggestion.location.isEmpty, suggestion.location != context {
                Text(suggestion.location).font(.footnote).foregroundStyle(Brand.muted)
            }
            comparison(suggestion, compact: true)
            if suggestion.isFillerRemoval {
                Text("No new achievement added.").font(.footnote).foregroundStyle(Brand.muted)
            }
            Button { open(suggestion) } label: {
                HStack {
                    Text("Review change")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold))
                }
                .font(Typeface.body).foregroundStyle(Brand.accent).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(busy).accessibilityLabel("Review change: \(suggestion.title)")
        }
        .padding(12)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Brand.rule, lineWidth: 0.5) }
    }

    private func focusedContent(_ suggestion: TailoringSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !suggestion.location.isEmpty, suggestion.location != context {
                Text(suggestion.location).font(Typeface.body).foregroundStyle(Brand.muted)
            }
            badge(suggestion.isFillerRemoval ? "REMOVE FILLER" : suggestion.label, accent: true)
            comparison(suggestion, compact: false)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Brand.rule, lineWidth: 0.5) }
            if !suggestion.reason.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Why this change?").font(.system(size: 22, weight: .bold)).foregroundStyle(Brand.ink)
                    Text(suggestion.reason).font(.system(size: 20)).foregroundStyle(Brand.ink)
                    if suggestion.isFillerRemoval {
                        Text("This is a wording cleanup. No new achievement is added.")
                            .font(Typeface.caption).foregroundStyle(Brand.muted)
                    }
                }
            }
        }
    }

    @ViewBuilder private func comparison(_ suggestion: TailoringSuggestion, compact: Bool) -> some View {
        if suggestion.isOrder, !suggestion.proposedItems.isEmpty {
            orderRows(suggestion, original: !compact && showOriginalOrder)
            if !compact {
                Button(showOriginalOrder ? "Show suggested order" : "Compare original order") { showOriginalOrder.toggle() }
                    .font(Typeface.body).foregroundStyle(Brand.accent).frame(minHeight: 44)
            }
            Divider().overlay(Brand.rule)
            Text("Order only · wording reviewed separately").font(.footnote).foregroundStyle(Brand.muted)
        } else {
            VStack(alignment: .leading, spacing: compact ? 8 : 14) {
                if !suggestion.before.isEmpty, !suggestion.legacyRecordOrder {
                    comparisonLabel("YOUR ORIGINAL", compact: compact)
                    Text(originalText(suggestion)).font(compact ? Typeface.caption : .system(size: 20))
                        .foregroundStyle(Brand.ink).textSelection(.enabled)
                    Divider().overlay(Brand.rule)
                }
                comparisonLabel("SUGGESTED VERSION", compact: compact)
                Text(suggestion.kind == "omit" ? "Leave this content out of this version."
                     : (suggestion.legacyRecordOrder ? "Reorder bullets for this role." : suggestion.after))
                    .font(compact ? Typeface.caption : .system(size: 20)).foregroundStyle(Brand.ink).textSelection(.enabled)
                if suggestion.isOrder, suggestion.before.isEmpty || suggestion.legacyRecordOrder {
                    Text("The exact order comparison isn’t available for this suggestion.")
                        .font(.footnote).foregroundStyle(Brand.muted)
                }
            }
        }
    }

    private func comparisonLabel(_ title: String, compact: Bool) -> some View {
        Text(compact ? title.replacingOccurrences(of: "YOUR ", with: "").replacingOccurrences(of: " VERSION", with: "") : title)
            .font(.system(size: 12, weight: .semibold)).tracking(0.4).foregroundStyle(Brand.muted)
    }

    private func orderRows(_ suggestion: TailoringSuggestion, original: Bool) -> some View {
        let items = original ? suggestion.originalItems : suggestion.proposedItems
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let previous = suggestion.originalItems.firstIndex { $0["id"] == item["id"] } ?? index
                HStack(alignment: .top, spacing: 10) {
                    badge(original ? "\(index + 1)" : "\(previous + 1) → \(index + 1)", accent: !original && previous != index)
                    Text(item["text"].string.replacingOccurrences(of: "**", with: ""))
                        .font(Typeface.caption).foregroundStyle(Brand.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func badge(_ text: String, accent: Bool) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent ? Brand.accent : Brand.muted).padding(.horizontal, 9).padding(.vertical, 5)
            .background(accent ? Brand.accent.opacity(0.12) : Brand.rule.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }

    private func originalText(_ suggestion: TailoringSuggestion) -> AttributedString {
        let words = suggestion.before.components(separatedBy: " ")
        let other = suggestion.after.components(separatedBy: " ")
        let removed = Set(words.map { $0.lowercased() }.difference(from: other.map { $0.lowercased() }).compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change { return offset }
            return nil
        })
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            var part = AttributedString(word + (index == words.count - 1 ? "" : " "))
            if !suggestion.isOrder, removed.contains(index) {
                part.backgroundColor = Palette.danger.opacity(0.12)
                part.strikethroughStyle = .single
            }
            result.append(part)
        }
        return result
    }

    private func open(_ suggestion: TailoringSuggestion) {
        focusedID = suggestion.id
        showOriginalOrder = false
        showAll = false
    }

    private func decide(_ suggestion: TailoringSuggestion, reject: Bool) {
        onSetRejected([suggestion.id], reject)
        let decided = Set(reviewed + [suggestion.id])
        if let next = suggestions.first(where: { !decided.contains($0.id) }) { open(next) }
        else { showAll = true }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if !error.isEmpty { MessageLine(text: error) }
            if !review["blocked"].string.isEmpty { MessageLine(text: review["blocked"].string) }
            if overview {
                PrimaryPill(title: busy ? "Applying changes…" : (complete ? "Apply changes" : "Continue reviewing"),
                            disabled: busy || !review["blocked"].string.isEmpty) {
                    if complete { onApply() }
                    else if let next = suggestions.first(where: { !reviewed.contains($0.id) }) { open(next) }
                }
            } else if let current {
                HStack(spacing: 10) {
                    Button { decide(current, reject: true) } label: {
                        Text("Keep original").font(.headline).foregroundStyle(Brand.ink)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Brand.muted.opacity(0.4), lineWidth: 1) }
                    }
                    .buttonStyle(.plain).disabled(busy)
                    PrimaryPill(title: "Use suggestion", disabled: busy) { decide(current, reject: false) }
                }
            }
            Text("Your original stays unchanged.").font(.footnote).foregroundStyle(Brand.muted)
            if !overview {
                Button("See all suggestions") { showAll = true }
                    .font(Typeface.body).foregroundStyle(Brand.accent).frame(minHeight: 44).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12).background(Brand.page)
    }

    private var details: some View {
        SheetPage(title: "Tailoring details") {
            if hasPreview { Button("Preview proposed PDF", action: onPreview) }
            if !review["summary"].string.isEmpty { Text(review["summary"].string) }
            if !review["score"]["after"].isNull {
                ScoreCardView(after: review["score"]["after"], before: review["score"]["before"], title: "Score with all suggestions")
            }
            if !review["dropped"].array.isEmpty { DroppedList(dropped: review["dropped"].array) }
            ForEach(Array(review["notes"].strings.enumerated()), id: \.offset) { _, note in
                Text(note.components(separatedBy: "Source:")[0]).font(Typeface.caption)
            }
            if !review["consequence"].string.isEmpty { Text(review["consequence"].string).font(Typeface.caption) }
        }
    }
}

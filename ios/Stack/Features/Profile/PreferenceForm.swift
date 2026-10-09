import SwiftUI

/// The editable form of saved matching preferences. Text fields stay strings; the server validates
/// every value, exactly as it does for the other clients.
struct PreferenceForm: Equatable {
    var stage = ""
    var years = ""
    var education = ""
    var modes: [String] = []
    var employmentTypes: [String] = []
    var salaryMin = ""
    var salaryPeriod = "year"
    var excludeCompanies = ""
    var excludeTerms = ""
    var soft: [String] = []

    init() {}

    init(_ preferences: JSON) {
        stage = preferences["stage"].string
        years = preferences["years"].isNull ? "" : preferences["years"].string
        education = preferences["education"].string
        modes = preferences["modes"].strings
        employmentTypes = preferences["employment_types"].strings
        let minimum = preferences["salary_min"].double
        salaryMin = minimum > 0 ? preferences["salary_min"].string : ""
        let period = preferences["salary_period"].string
        salaryPeriod = period.isEmpty ? "year" : period
        excludeCompanies = preferences["exclude_companies"].strings.joined(separator: ", ")
        excludeTerms = preferences["exclude_terms"].strings.joined(separator: ", ")
        soft = preferences["soft"].strings
    }

    /// The `preferences` argument of `save_profile`.
    var json: JSON {
        [
            "stage": .string(stage),
            "years": .string(years),
            "education": .string(education),
            "modes": .array(modes.map { .string($0) }),
            "employment_types": .array(employmentTypes.map { .string($0) }),
            "salary_min": .string(salaryMin),
            "salary_period": .string(salaryPeriod),
            "exclude_companies": .string(excludeCompanies),
            "exclude_terms": .string(excludeTerms),
            "soft": .array(soft.map { .string($0) }),
        ]
    }
}

/// Wrapping row of single- or multi-select chips.
struct ChoiceChips: View {
    let options: [String]
    let isSelected: (String) -> Bool
    let onTap: (String) -> Void
    var labelFor: (String) -> String = { $0 }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Chip(label: labelFor(option), selected: isSelected(option)) { onTap(option) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Matching inputs shared by profile editing and job search.
struct MatchInputsView: View {
    @Binding var form: PreferenceForm
    var showStage = true

    private let niceToHave: [(key: String, label: String)] = [
        ("location", "Location"), ("modes", "Work arrangement"), ("employment_types", "Employment type"),
        ("salary", "Pay"), ("level", "Level"), ("experience", "Experience"), ("education", "Education"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showStage {
                group("Career stage") {
                    ChoiceChips(options: ["Student", "Recent graduate", "Early career", "Experienced", "Career changer"],
                                isSelected: { form.stage == $0 }, onTap: { form.stage = form.stage == $0 ? "" : $0 })
                }
            }
            StackField(label: "Years of experience in this field", text: $form.years, placeholder: "For example, 2", keyboard: .numbersAndPunctuation)
            group("Education, completed or in progress") {
                ChoiceChips(options: ["High school", "Associate", "Bachelor's", "Master's", "Doctorate"],
                            isSelected: { form.education == $0 }, onTap: { form.education = form.education == $0 ? "" : $0 })
            }
            group("Open to") {
                ChoiceChips(options: ["Remote", "Hybrid", "On-site"],
                            isSelected: { form.modes.contains($0) }, onTap: { form.modes = form.modes.toggled($0) })
                Text("Leave all off for any work arrangement.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            group("Employment type") {
                ChoiceChips(options: ["Full-time", "Part-time", "Contract", "Temporary", "Internship"],
                            isSelected: { form.employmentTypes.contains($0) },
                            onTap: { form.employmentTypes = form.employmentTypes.toggled($0) })
            }
            StackField(label: "Minimum pay (USD)", text: $form.salaryMin, placeholder: "Optional", keyboard: .decimalPad)
            ChoiceChips(options: ["hour", "year"], isSelected: { form.salaryPeriod == $0 },
                        onTap: { form.salaryPeriod = $0 }, labelFor: { "per " + $0 })
            StackField(label: "Hide these employers", text: $form.excludeCompanies, placeholder: "Separate with commas")
            StackField(label: "Hide jobs mentioning", text: $form.excludeTerms, placeholder: "Separate with commas")
            group("Nice to have, not required") {
                ChoiceChips(options: niceToHave.map(\.key), isSelected: { form.soft.contains($0) },
                            onTap: { form.soft = form.soft.toggled($0) },
                            labelFor: { key in niceToHave.first { $0.key == key }?.label ?? key })
                Text("Jobs that conflict with a requirement are hidden. Nice-to-haves only change the order. When a listing doesn’t say, the job stays visible and is marked unconfirmed.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typeface.caption).foregroundStyle(Palette.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

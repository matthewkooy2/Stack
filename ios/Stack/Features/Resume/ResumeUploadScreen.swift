import SwiftUI

/// The first-use upload surface is shared with the optional onboarding step.
struct ResumeUploadScreen: View {
    var uploading = false
    var fileName = ""
    var disabled = false
    var error = ""
    var progress = ""
    let onUpload: () -> Void
    var onProfile: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        Page {
            if let onProfile {
                ScreenHeader(title: "Resume", onProfile: onProfile)
            }
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "doc.text")
                    .font(.largeTitle.weight(.regular))
                    .foregroundStyle(Brand.accent)
                    .padding(18)
                    .background(Palette.halo, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Upload your resume")
                        .font(Typeface.title).foregroundStyle(Brand.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose a file to review your experience and tailor it for a job.")
                        .font(Typeface.body).foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !error.isEmpty {
                    MessageLine(text: error).accessibilityIdentifier("resume-upload-error")
                }
                if let onRetry, !uploading {
                    StackButton(label: "Try again", icon: "refresh", disabled: disabled, action: onRetry)
                        .accessibilityIdentifier("resume-upload-retry")
                }
                StackButton(label: uploading ? "Preparing resume…" : "Choose file", icon: "upload",
                            kind: onRetry == nil ? .primary : .secondary,
                            disabled: uploading || disabled, action: onUpload)
                    .accessibilityLabel(uploading ? "Uploading resume" : "Upload resume")
                    .accessibilityHint("Choose a PDF or DOCX, up to 10 megabytes.")
                    .accessibilityIdentifier("resume-upload")
                HStack(spacing: 8) {
                    if uploading { ProgressView().tint(Brand.accent) }
                    Text(caption).font(Typeface.caption).foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("resume-upload-status")
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .background(Brand.page.ignoresSafeArea())
    }

    private var caption: String {
        if uploading { return progress.isEmpty ? (fileName.isEmpty ? "Uploading…" : "Uploading \(fileName)") : progress }
        if onRetry != nil, !fileName.isEmpty { return fileName }
        return "PDF or DOCX · Up to 10 MB"
    }
}

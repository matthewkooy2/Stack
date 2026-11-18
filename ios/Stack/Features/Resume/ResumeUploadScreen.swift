import SwiftUI

/// Shared by the optional onboarding step and the empty document library.
struct ResumeUploadScreen: View {
    var uploading = false
    var fileName = ""
    var disabled = false
    var error = ""
    var progress = ""
    let onUpload: () -> Void
    var onRetry: (() -> Void)?

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                invitation
                    .frame(minHeight: viewport.size.height)
                    .padding(.horizontal, Spacing.page)
            }
        }
        .background(Brand.page.ignoresSafeArea())
    }

    var invitation: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Palette.halo)
                    .frame(width: 76, height: 98)
                    .rotationEffect(.degrees(-10))
                    .offset(x: -7, y: 1)
                ResumePaper().frame(width: 78, height: 102)
                    .rotationEffect(.degrees(4))
                    .offset(x: 5)
            }
            .padding(.vertical, 6)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Add your resume")
                    .font(Typeface.title).foregroundStyle(Brand.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("PDF or DOCX · Up to 10 MB")
                    .font(Typeface.caption).foregroundStyle(Brand.muted)
            }

            if !error.isEmpty {
                MessageLine(text: error).accessibilityIdentifier("resume-upload-error")
            }
            VStack(spacing: 4) {
                if let onRetry, !uploading {
                    StackButton(label: "Try again", disabled: disabled, action: onRetry)
                        .accessibilityIdentifier("resume-upload-retry")
                    StackButton(label: "Choose another resume", kind: .secondary, disabled: disabled, action: onUpload)
                        .accessibilityIdentifier("resume-upload")
                } else {
                    StackButton(label: uploading ? "Uploading…" : "Choose resume", disabled: uploading || disabled, action: onUpload)
                        .accessibilityHint("PDF or DOCX, up to 10 MB")
                        .accessibilityIdentifier("resume-upload")
                }
                if uploading || onRetry != nil {
                    Text(uploading ? (progress.isEmpty ? "Uploading…" : progress) : fileName)
                        .font(Typeface.caption).foregroundStyle(Brand.muted)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("resume-upload-status")
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

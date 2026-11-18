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
                    .font(.title2.weight(.semibold)).foregroundStyle(Brand.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("PDF or DOCX · Up to 10 MB")
                    .font(Typeface.caption).foregroundStyle(Brand.muted)
            }

            if !error.isEmpty {
                MessageLine(text: error).accessibilityIdentifier("resume-upload-error")
            }
            VStack(spacing: 4) {
                if let onRetry, !uploading {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .controlSize(.large).tint(Palette.button).foregroundStyle(.white)
                        .disabled(disabled).accessibilityIdentifier("resume-upload-retry")
                    Button("Choose another file", action: onUpload)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
                        .frame(minHeight: 44).disabled(disabled)
                        .accessibilityIdentifier("resume-upload")
                } else {
                    Button(action: onUpload) {
                        if uploading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Choose file")
                        }
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .controlSize(.large).tint(Palette.button).foregroundStyle(.white)
                    .disabled(uploading || disabled)
                    .accessibilityLabel(uploading ? "Uploading resume" : "Choose file")
                    .accessibilityHint("Choose a PDF or DOCX, up to 10 megabytes.")
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

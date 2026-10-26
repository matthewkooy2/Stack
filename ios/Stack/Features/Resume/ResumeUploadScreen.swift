import SwiftUI

/// The first-use Resume screen. The paper stack is the upload button, not a second illustration above one.
struct ResumeUploadScreen: View {
    var uploading = false
    var disabled = false
    var error = ""
    var attentionCount = 0
    let onUpload: () -> Void
    var onProfile: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 36

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("Resume").font(.system(.headline).weight(.semibold)).foregroundStyle(Brand.ink)
                        Spacer()
                        if let onProfile {
                            Button(action: onProfile) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 24, weight: .regular)).foregroundStyle(Brand.muted)
                                    .frame(width: 44, height: 44)
                                    .overlay(alignment: .topTrailing) {
                                        if attentionCount > 0 {
                                            Circle().fill(Brand.accent).frame(width: 8, height: 8)
                                                .padding(5)
                                        }
                                    }
                            }
                            .buttonStyle(.tap(scale: 0.92, dim: 1))
                            .accessibilityLabel(attentionCount > 0
                                ? "Your account, \(attentionCount) agent tasks need you" : "Your account")
                        }
                    }
                    .frame(minHeight: 44)

                    Text("Upload your\nresume")
                        .font(.system(size: headingSize, weight: .heavy)).tracking(-1.5)
                        .foregroundStyle(Brand.ink).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, max(32, min(72, geometry.size.height * 0.10)))
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: 8)
                    Button(action: onUpload) {
                        ResumeStackMark()
                            .frame(width: 246, height: 264)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.tap(scale: 0.97))
                    .disabled(uploading || disabled)
                    .accessibilityLabel(uploading ? "Uploading resume" : "Upload resume")
                    .accessibilityHint("Choose a PDF, up to 10 megabytes.")
                    .accessibilityIdentifier("resume-upload")

                    HStack(spacing: 8) {
                        if uploading { ProgressView().tint(Brand.accent) }
                        Text(uploading ? "Uploading…" : "PDF · Up to 10 MB")
                            .font(Typeface.caption).foregroundStyle(Brand.muted)
                    }
                    .frame(minHeight: 24)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)

                    if !error.isEmpty {
                        Text(error).font(Typeface.caption).foregroundStyle(Palette.danger)
                            .multilineTextAlignment(.center).padding(.top, 12)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Spacer(minLength: 48)
                }
                .padding(.horizontal, Spacing.page)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Brand.page.ignoresSafeArea())
    }
}

/// Five paper layers land back-to-front with the same spring and 50 ms cadence as StackMark's coins.
/// Fixed final offsets give the assembled icon depth; only the entrance offset is animated.
struct ResumeStackMark: View {
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(\.launchHold) private var hold
    @State private var built = false

    private var shown: Bool { built || reduceMotion }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5) { index in
                sheet(index)
                    .offset(x: CGFloat(4 - index) * 4, y: CGFloat(4 - index) * 5.5)
                    .offset(y: shown ? 0 : -140)
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72)
                        .delay(0.1 + Double(index) * 0.05), value: built)
            }
        }
        .frame(width: 280, height: 340)
        .scaleEffect(264.0 / 340.0)
        .frame(width: 246, height: 264)
        .clipped()
        .accessibilityHidden(true)
        .onAppear { start() }
        .onChange(of: hold) { _, held in if !held { start() } }
    }

    private func start() {
        guard !hold, !built else { return }
        if reduceMotion { built = true }
        else { DispatchQueue.main.async { built = true } }
    }

    private func sheet(_ index: Int) -> some View {
        let tint = [1.0, 0.4, 0.16, 0.04, 0.0][index]
        return ZStack {
            ResumePaperShape().fill(.white)
            ResumePaperShape().fill(Brand.accent.opacity(tint))
            ResumePaperShape().stroke(Brand.accent.opacity(index == 4 ? 1 : 0.5),
                                     style: StrokeStyle(lineWidth: index == 4 ? 2.4 : 1, lineJoin: .round))
            if index == 4 {
                ResumePaperFold().fill(.white)
                ResumePaperFold().fill(Brand.accent.opacity(0.12))
                ResumePaperFold().stroke(Brand.accent, style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: 88, y: 117)); path.addLine(to: CGPoint(x: 143, y: 117))
                    path.move(to: CGPoint(x: 88, y: 137)); path.addLine(to: CGPoint(x: 125, y: 137))
                }
                .stroke(Brand.accent.opacity(0.22), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                Path { path in
                    path.move(to: CGPoint(x: 140, y: 224)); path.addLine(to: CGPoint(x: 140, y: 173))
                    path.move(to: CGPoint(x: 122, y: 191)); path.addLine(to: CGPoint(x: 140, y: 173))
                    path.addLine(to: CGPoint(x: 158, y: 191))
                    path.move(to: CGPoint(x: 111, y: 225)); path.addLine(to: CGPoint(x: 111, y: 238))
                    path.addLine(to: CGPoint(x: 169, y: 238)); path.addLine(to: CGPoint(x: 169, y: 225))
                }
                .stroke(Brand.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 280, height: 340)
        .compositingGroup()
        .shadow(color: Brand.ink.opacity(index == 4 ? 0.12 : 0.09), radius: index == 4 ? 4 : 3, y: 3)
    }
}

private struct ResumePaperShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 82, y: 78))
        path.addLine(to: CGPoint(x: 174, y: 78))
        path.addLine(to: CGPoint(x: 214, y: 118))
        path.addLine(to: CGPoint(x: 214, y: 248))
        path.addQuadCurve(to: CGPoint(x: 198, y: 264), control: CGPoint(x: 214, y: 264))
        path.addLine(to: CGPoint(x: 82, y: 264))
        path.addQuadCurve(to: CGPoint(x: 66, y: 248), control: CGPoint(x: 66, y: 264))
        path.addLine(to: CGPoint(x: 66, y: 94))
        path.addQuadCurve(to: CGPoint(x: 82, y: 78), control: CGPoint(x: 66, y: 78))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 280, y: rect.height / 340))
    }
}

private struct ResumePaperFold: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 174, y: 78))
        path.addLine(to: CGPoint(x: 174, y: 107))
        path.addQuadCurve(to: CGPoint(x: 185, y: 118), control: CGPoint(x: 174, y: 118))
        path.addLine(to: CGPoint(x: 214, y: 118))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 280, y: rect.height / 340))
    }
}

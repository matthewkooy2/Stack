import SwiftUI
import UIKit

/// The existing remote browser connection inside the LinkedIn design's viewport.
@MainActor
struct LinkedInBrowser: View {
    @Bindable var model: RemoteBrowserModel
    let height: CGFloat
    @State private var keyboard = UITextField()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "lock.fill").font(.system(size: 12)).accessibilityHidden(true)
                Text(model.frame?.url ?? "linkedin.com")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { model.reconnect() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15))
                }.accessibilityLabel("Reconnect browser")
            }
            .foregroundStyle(Palette.muted).padding(.horizontal, 15).frame(height: 42)
            .background(Palette.field)
            GeometryReader { geometry in
                ZStack {
                    Color.white
                    if let frame = model.frame {
                        Image(uiImage: frame.image).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        ProgressView().tint(Palette.muted)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    if abs(value.translation.height) > 12 || abs(value.translation.width) > 12 {
                        model.send(["type": "scroll", "dy": .number(-Double(value.translation.height) * 2)])
                    } else if let frame = model.frame {
                        let scale = min(geometry.size.width / frame.width, geometry.size.height / frame.height)
                        let x = (value.startLocation.x - (geometry.size.width - frame.width * scale) / 2) / scale
                        let y = (value.startLocation.y - (geometry.size.height - frame.height * scale) / 2) / scale
                        model.send(["type": "click", "x": .number(x), "y": .number(y)])
                        keyboard.becomeFirstResponder()
                    }
                })
                .accessibilityLabel("Live remote browser")
            }
            .frame(height: height)
            MessageLine(text: model.error).fadeSwitch(!model.error.isEmpty)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Spacing.cardRadius).stroke(Palette.rule, lineWidth: 1) }
        .background {
            LinkedInBrowserKeyboard(field: keyboard, send: model.send)
                .frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true)
        }
    }
}

/// Forward native keyboard input to the already-focused field in the remote page.
@MainActor
private struct LinkedInBrowserKeyboard: UIViewRepresentable {
    let field: UITextField
    let send: (JSON) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(send: send) }

    func makeUIView(context: Context) -> UITextField {
        field.delegate = context.coordinator
        field.text = "\u{200B}"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.isSecureTextEntry = true
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(title: "Tab", primaryAction: UIAction { _ in send(["type": "key", "key": "Tab"]) }),
            UIBarButtonItem(title: "Enter", primaryAction: UIAction { _ in send(["type": "key", "key": "Enter"]) }),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "Done", primaryAction: UIAction { _ in field.resignFirstResponder() })
        ]
        toolbar.sizeToFit()
        field.inputAccessoryView = toolbar
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        let send: (JSON) -> Void
        init(send: @escaping (JSON) -> Void) { self.send = send }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            send(string.isEmpty ? ["type": "key", "key": "Backspace"] : ["type": "text", "text": .string(string)])
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            send(["type": "key", "key": "Enter"])
            return false
        }
    }
}

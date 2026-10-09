import SwiftUI
import UIKit

/// Server-sent frames and control state for a task's remote browser. Control authority lives on the
/// server; this client only displays the stream and sends confirmed, sequenced input.
@MainActor
@Observable
final class RemoteBrowserModel {
    struct Frame {
        var image: UIImage
        var width: Double
        var height: Double
        var captureID: String
        var sequence: Double
        var progress: String
        var url: String
    }

    var frame: Frame?
    var control: JSON = ["mode": "agent", "generation": 0]
    var connection = "connecting"
    var error = ""
    var busy = false
    var age: Double = .infinity
    var safe = true

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var id = ""
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var sequence: Double = 0
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var receivedAt: Date?
    @ObservationIgnored private var receivedAge: Double = 0
    @ObservationIgnored private var onChanged: (() -> Void)?
    let controllerID = "viewer-" + String(Int(Date().timeIntervalSince1970), radix: 36) + "-" + UUID().uuidString.prefix(8).lowercased()

    var owned: Bool { control["mode"].string == "user" && control["controller"].string == controllerID }
    var canInput: Bool { owned && connection == "connected" && age < 5000 && safe }

    var statusText: String {
        let mode = control["mode"].string
        if mode == "pausing" { return "Pausing agent…" }
        if mode == "stopping" { return "Stopping task…" }
        if mode == "stopped" { return "Task stopped" }
        if connection == "unavailable" { return "Browser unavailable" }
        if connection == "unconfirmed" || !safe { return "Input unconfirmed" }
        if connection != "connected" { return "Reconnecting…" }
        if age >= 5000 { return "Waiting for a fresh view…" }
        if owned { return "You have control" }
        if mode == "user" { return "Another viewer has control" }
        return "Agent has browser control"
    }

    func open(store: AppStore, id: String, onChanged: @escaping () -> Void) {
        self.store = store
        self.id = id
        self.onChanged = onChanged
        connect()
    }

    func close() {
        streamTask?.cancel()
        streamTask = nil
        epoch += 1
    }

    /// Phone left the foreground: stop streaming and drop any unsent input.
    func background() {
        streamTask?.cancel()
        streamTask = nil
        epoch += 1
        connection = "background"
    }

    func reconnect() {
        epoch += 1
        connect()
    }

    func tick() {
        if let receivedAt { age = receivedAge + Date().timeIntervalSince(receivedAt) * 1000 } else { age = .infinity }
    }

    // MARK: Stream

    private func connect() {
        streamTask?.cancel()
        connection = "connecting"
        guard let store else { return }
        let generation = store.sessionGeneration
        let token = store.api.token
        let origin = store.api.origin
        let identifier = id
        streamTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, store.sessionGeneration == generation else { return }
                self.connection = attempt == 0 ? "connecting" : "reconnecting"
                attempt += 1
                var request = URLRequest(url: origin.appendingPathComponent("browser/stream"))
                request.httpMethod = "POST"
                request.timeoutInterval = 35
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = try? JSONEncoder().encode(JSON.object(["id": .string(identifier)]))
                var status = 0
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 401 || status == 403 {
                        self.connection = "unavailable"
                        return
                    }
                    if status == 200 {
                        for try await line in bytes.lines {
                            if Task.isCancelled { return }
                            guard line.hasPrefix("data: "),
                                  let data = line.dropFirst(6).data(using: .utf8),
                                  let value = try? JSONDecoder().decode(JSON.self, from: data) else { continue }
                            self.connection = "connected"
                            self.receive(value)
                            if self.control["mode"].string == "stopped" { return }
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                self.connection = "reconnecting"
                let delay = status == 200 ? 0.15 : min(5.0, 0.5 * Double(attempt))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func receive(_ event: JSON) {
        if !event["control"].isNull {
            let incoming = event["control"]
            let known = control
            if incoming["instance"] == known["instance"], incoming["generation"].double < known["generation"].double { return }
            if incoming["instance"] != known["instance"] {
                sequence = 0
                frame = nil
            }
            if incoming["instance"] != known["instance"] || incoming["generation"] != known["generation"] { epoch += 1 }
            sequence = max(sequence, incoming["sequence"].double)
            control = incoming
        }
        if !event["frame"]["image"].string.isEmpty { setFrame(event["frame"]) }
        receivedAt = Date()
        receivedAge = max(0, (event["server_time"].double - event["observed_at"].double) * 1000)
        age = receivedAge
        if event["control"]["revoked"].bool || event["control"]["mode"].string == "stopped" { frame = nil }
        if control["mode"].string == "stopped" {
            streamTask?.cancel()
            streamTask = nil
            connection = "stopped"
            onChanged?()
        }
    }

    private func setFrame(_ value: JSON) {
        guard let data = Data(base64Encoded: value["image"].string), let image = UIImage(data: data) else { return }
        let capture = value["capture_id"].string
        let next = Frame(image: image, width: value["width"].double, height: value["height"].double,
                         captureID: capture, sequence: value["sequence"].double,
                         progress: value["progress"].string, url: value["url"].string)
        if let current = frame, capture == current.captureID, next.sequence < current.sequence { return }
        frame = next
    }

    // MARK: Input

    func send(_ input: JSON) {
        guard canInput, let store else { return }
        let observed = epoch
        let generation = control["generation"]
        let instance = control["instance"]
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self, self.epoch == observed, self.safe else { return }
            self.sequence += 1
            var payload = input
            payload["generation"] = generation
            payload["instance"] = instance
            payload["controller"] = .string(self.controllerID)
            payload["sequence"] = .number(self.sequence)
            do {
                let result = try await store.call("agent_browser", ["id": .string(self.id), "event": payload])
                guard self.epoch == observed else { return }
                if !result["error"].string.isEmpty { throw APIError(message: result["error"].string) }
                if !result["image"].string.isEmpty { self.setFrame(result) }
                self.error = ""
            } catch {
                guard self.epoch == observed, !(error is CancellationError) else { return }
                self.safe = false
                self.error = "Input was not confirmed. Take control again before continuing."
                self.connection = "unconfirmed"
            }
        }
    }

    func act(_ name: String) async {
        guard !busy, let store else { return }
        busy = true
        error = ""
        defer { busy = false }
        if name == "resume" {
            await chain?.value
            guard safe else {
                error = "Reconnect to confirm your last input before resuming."
                return
            }
        } else {
            epoch += 1
        }
        do {
            let result = try await store.call("agent_browser_control", [
                "id": .string(id), "action": .string(name), "generation": control["generation"],
                "instance": control["instance"], "controller": .string(controllerID),
            ])
            if !result["error"].string.isEmpty { throw APIError(message: result["error"].string) }
            if !result["control"].isNull {
                control = result["control"]
                sequence = result["control"]["sequence"].double
                if name == "take" { safe = true }
            }
            if name != "stop" || result["control"]["mode"].string == "stopped" { onChanged?() }
            if name == "stop", result["control"].isNull { connection = "stopping" }
        } catch {
            if !(error is CancellationError) {
                self.error = error.localizedDescription.isEmpty
                    ? "Control could not be confirmed. Reconnect before continuing." : error.localizedDescription
            }
        }
    }
}

/// The collapsed entry in a task: one button that opens the live browser full screen.
struct BrowserEntryView: View {
    let id: String
    let task: JSON
    let onChanged: () -> Void
    @State private var open = false

    var body: some View {
        StackButton(label: "Open browser", icon: "link") { open = true }
            .fullScreenCover(isPresented: $open) {
                RemoteBrowserView(id: id, task: task, onChanged: onChanged)
            }
    }
}

struct RemoteBrowserView: View {
    let id: String
    let task: JSON
    let onChanged: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = RemoteBrowserModel()
    @State private var text = ""
    @State private var area: CGSize = .zero
    @State private var dragStart: CGPoint?

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Browser").font(Typeface.title).foregroundStyle(Palette.ink)
                    Spacer()
                    StackButton(label: "Close", kind: .secondary) { dismiss() }.frame(width: 90)
                }
                Text(model.statusText).font(Typeface.body).foregroundStyle(Palette.text).accessibilityAddTraits(.updatesFrequently)
                taskStatus
                if let url = model.frame?.url, !url.isEmpty {
                    Text(url).font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
                screen
                MessageLine(text: model.error).fadeSwitch(!model.error.isEmpty)
                if model.owned {
                    Text("Tap a field to focus it, type below, and send. Swipe the page to scroll. Closing this view leaves the agent paused.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    HStack(spacing: 8) {
                        TextField("Text to type", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Palette.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .disabled(!model.canInput)
                            .accessibilityLabel("Remote browser keyboard")
                        Chip(label: "Send") { flush() }
                    }
                    HStack(spacing: 8) {
                        Chip(label: "Backspace") { flush(); model.send(["type": "key", "key": "Backspace"]) }
                        Chip(label: "Tab") { flush(); model.send(["type": "key", "key": "Tab"]) }
                        Chip(label: "Enter") { flush(); model.send(["type": "key", "key": "Enter"]) }
                    }
                }
                controls
            }
            .padding(Spacing.page)
        }
        .task {
            model.open(store: store, id: id, onChanged: onChanged)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                model.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.reconnect() } else { model.background() }
        }
        .onDisappear { model.close() }
    }

    private var taskStatus: some View {
        let labels = ["running": "Agent is working", "queued": "Queued for the agent", "needs_input": "Your input is needed",
                      "paused": "Task paused", "review": "Waiting for approval", "uncertain": "Check what happened",
                      "blocked": "Task blocked", "cancelled": "Task cancelled", "failed": "Task failed", "completed": "Task finished"]
        let live = task["id"].string == id ? task : [:]
        return VStack(alignment: .leading, spacing: 4) {
            Text(labels[live["status"].string] ?? "Waiting for task status").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            if !live["step_label"].string.isEmpty { Text(live["step_label"].string).font(Typeface.caption).foregroundStyle(Palette.muted) }
            if !live["message"].string.isEmpty { Text(live["message"].string).font(Typeface.caption).foregroundStyle(Palette.muted) }
            if let progress = model.frame?.progress, !progress.isEmpty {
                Text("Browser progress: \(progress)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var screen: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white
                if let frame = model.frame {
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(model.connection == "connected" && model.age < 5000 ? 1 : 0.55)
                } else {
                    Text("Opening the task’s browser…").font(Typeface.caption).foregroundStyle(Palette.muted).padding(24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.rule, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in if dragStart == nil { dragStart = value.startLocation } }
                    .onEnded { value in
                        defer { dragStart = nil }
                        guard model.canInput else { return }
                        flush()
                        if abs(value.translation.height) > 12 || abs(value.translation.width) > 12 {
                            model.send(["type": "scroll", "dy": .number(-Double(value.translation.height) * 2)])
                        } else if let point = map(value.startLocation, in: proxy.size) {
                            model.send(["type": "click", "x": .number(point.x), "y": .number(point.y)])
                        }
                    }
            )
            .accessibilityLabel("Live remote browser")
            .onAppear { area = proxy.size }
        }
        .frame(minHeight: 240)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if model.owned, model.safe {
                StackButton(label: "Resume agent", disabled: model.busy || model.connection != "connected") {
                    flush()
                    Task { await model.act("resume") }
                }
            } else {
                StackButton(label: "Take control",
                            disabled: model.busy || model.connection != "connected" || !["agent", "user"].contains(model.control["mode"].string)) {
                    Task { await model.act("take") }
                }
            }
            StackButton(label: "Stop task", kind: .secondary,
                        disabled: model.busy || ["stopping", "stopped"].contains(model.control["mode"].string)) {
                Task { await model.act("stop") }
            }
            if !["connected", "stopped"].contains(model.connection) || model.age >= 5000 {
                StackButton(label: "Reconnect", kind: .secondary, disabled: model.busy) { model.reconnect() }
            }
        }
    }

    private func flush() {
        let value = text
        text = ""
        if !value.isEmpty { model.send(["type": "text", "text": .string(value)]) }
    }

    /// Maps a point in the letterboxed view back to page coordinates.
    private func map(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard let frame = model.frame, frame.width > 0, frame.height > 0 else { return nil }
        let scale = min(size.width / frame.width, size.height / frame.height)
        let x = (location.x - (size.width - frame.width * scale) / 2) / scale
        let y = (location.y - (size.height - frame.height * scale) / 2) / scale
        guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return nil }
        return CGPoint(x: x, y: y)
    }
}

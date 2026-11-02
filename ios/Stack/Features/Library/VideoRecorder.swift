@preconcurrency import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Records one front-camera answer to a local movie file. When the camera is unavailable or
/// refused, it records audio only through the same session so scoring still works.
@MainActor
@Observable
final class VideoRecorder: NSObject {
    enum Phase: Equatable { case idle, preparing, ready, recording, finishing }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var cameraDenied = false
    /// False when access was granted but no front camera exists (for example the simulator).
    private(set) var cameraFound = true
    private(set) var microphoneDenied = false
    /// Why the recording ended on its own (time limit, call, app moved to background).
    private(set) var stopNotice = ""
    var error = ""

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "stack.practice.capture")
    @ObservationIgnored private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var finished: CheckedContinuation<URL, Error>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var hasVideo: Bool { !cameraDenied && cameraFound }
    var isRecording: Bool { phase == .recording }

    /// Asks for camera and microphone access and starts the preview.
    func prepare() async {
        guard phase == .idle else { return }
        phase = .preparing
        error = ""; stopNotice = ""
        let camera = await Self.access(.video)
        let microphone = await Self.access(.audio)
        cameraDenied = !camera
        microphoneDenied = !microphone
        guard microphone else {
            phase = .idle
            error = "Stack needs the microphone to hear your answer."
            return
        }
        do {
            // One shared route for the interviewer voice and the answer: loudspeaker out, mic in.
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
            cameraFound = try await configure(camera: camera) || !camera
            observe()
            phase = .ready
        } catch {
            phase = .idle
            self.error = error.localizedDescription
        }
    }

    private static func access(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    /// Returns whether a camera input was added.
    private func configure(camera: Bool) async throws -> Bool {
        let session = session, output = output
        let video = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            queue.async {
                session.automaticallyConfiguresApplicationAudioSession = false
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.inputs.forEach { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.sessionPreset = camera ? .high : .medium
                do {
                    var added = false
                    if camera, let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                        let input = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(input) { session.addInput(input); added = true }
                    }
                    guard let mic = AVCaptureDevice.default(for: .audio) else {
                        throw APIError(message: "No microphone is available.")
                    }
                    let audio = try AVCaptureDeviceInput(device: mic)
                    guard session.canAddInput(audio), session.canAddOutput(output) else {
                        throw APIError(message: "Recording is unavailable right now.")
                    }
                    session.addInput(audio)
                    session.addOutput(output)
                    output.maxRecordedDuration = CMTime(seconds: VideoLibraryStore.maximumSeconds, preferredTimescale: 600)
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                    continuation.resume(returning: added)
                } catch { continuation.resume(throwing: error) }
            }
        }
        queue.async { session.startRunning() }
        return video
    }

    func start(to url: URL) throws {
        guard phase == .ready else { throw APIError(message: "The camera is not ready yet.") }
        try? FileManager.default.removeItem(at: url)
        stopNotice = ""; error = ""
        phase = .recording
        started = Date()
        elapsed = 0
        let output = output
        queue.async { output.startRecording(to: url, recordingDelegate: self) }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .recording else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
            }
        }
    }

    /// Stops and returns the finished file.
    func stop() async throws -> URL {
        guard phase == .recording else { throw APIError(message: "Nothing is recording.") }
        phase = .finishing
        let output = output
        return try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            queue.async { output.stopRecording() }
        }
    }

    /// Ends capture without saving an answer, e.g. when the sheet closes.
    func shutdown() {
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let session = session, output = output
        queue.async {
            if output.isRecording { output.stopRecording() }
            session.stopRunning()
        }
        phase = .idle
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let interrupt: (String) -> Void = { [weak self] notice in
            guard let self, self.phase == .recording else { return }
            self.stopNotice = notice
            let output = self.output
            self.queue.async { output.stopRecording() }
        }
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { interrupt("Recording stopped when Stack left the screen. Your answer so far was kept.") }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { _ in
            MainActor.assumeIsolated { interrupt("Recording was interrupted, for example by a call. Your answer so far was kept.") }
        })
    }

    /// The recording ended on its own; the model picks the file up through `onAutoStop`.
    @ObservationIgnored var onAutoStop: ((Result<URL, Error>) -> Void)?

    fileprivate func didFinish(_ url: URL, _ failure: Error?) {
        timer?.cancel()
        elapsed = max(elapsed, Date().timeIntervalSince(started))
        // A file that reached the limit or was interrupted still finishes successfully.
        let usable = FileManager.default.fileExists(atPath: url.path)
            && ((failure as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (failure == nil))
        if (failure as NSError?)?.code == AVError.maximumDurationReached.rawValue {
            stopNotice = "You reached the \(Int(VideoLibraryStore.maximumSeconds / 60))-minute limit. Your answer was kept."
        }
        phase = .ready
        let result: Result<URL, Error> = usable ? .success(url) : .failure(failure ?? APIError(message: "The recording could not be saved."))
        if let finished {
            self.finished = nil
            finished.resume(with: result)
        } else {
            onAutoStop?(result)
        }
    }
}

extension VideoRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.didFinish(outputFileURL, error) }
    }
}

/// Live camera preview for the recorder's session.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.accessibilityLabel = "Camera preview"
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

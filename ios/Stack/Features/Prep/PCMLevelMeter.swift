import AVFoundation
import Foundation

// Input level for the recording surface. Every value comes from the PCM samples the
// capture tap actually delivered; nothing here is a timer-driven animation. The math
// is kept free of AVFoundation types so synthetic buffers can test it.

/// One buffer's amplitude on a 0...1 full-scale range.
struct PCMMeasurement: Equatable {
    var rms: Float
    var peak: Float
    /// Samples at or beyond `PCMAmplitude.clipThreshold`.
    var clippedSamples: Int
    var frames: Int

    static let empty = PCMMeasurement(rms: 0, peak: 0, clippedSamples: 0, frames: 0)

    /// Combines channels: the loudest channel decides level, clipping on any channel counts.
    func merged(with other: PCMMeasurement) -> PCMMeasurement {
        PCMMeasurement(rms: max(rms, other.rms), peak: max(peak, other.peak),
                       clippedSamples: clippedSamples + other.clippedSamples, frames: max(frames, other.frames))
    }
}

enum PCMAmplitude {
    /// A sample this close to full scale is treated as clipped.
    static let clipThreshold: Float = 0.985

    static func measure(floats samples: UnsafeBufferPointer<Float>) -> PCMMeasurement {
        measure(floats: samples.baseAddress, frames: samples.count, stride: 1)
    }

    static func measure(int16 samples: UnsafeBufferPointer<Int16>) -> PCMMeasurement {
        measure(int16: samples.baseAddress, frames: samples.count, stride: 1)
    }

    /// `stride` is the distance between consecutive frames of one channel: 1 for planar
    /// buffers, the channel count for interleaved ones (`AVAudioPCMBuffer.stride`).
    static func measure(floats base: UnsafePointer<Float>?, frames: Int, stride: Int) -> PCMMeasurement {
        guard let base, frames > 0, stride > 0 else { return .empty }
        var sum: Double = 0
        var peak: Float = 0
        var clipped = 0
        for index in 0..<frames {
            // A corrupt buffer must not poison the smoothed level.
            let raw = base[index * stride]
            let value = raw.isFinite ? abs(raw) : 0
            sum += Double(value) * Double(value)
            if value > peak { peak = value }
            if value >= clipThreshold { clipped += 1 }
        }
        let rms = Float((sum / Double(frames)).squareRoot())
        return PCMMeasurement(rms: min(rms, 1), peak: min(peak, 1), clippedSamples: clipped, frames: frames)
    }

    static func measure(int16 base: UnsafePointer<Int16>?, frames: Int, stride: Int) -> PCMMeasurement {
        guard let base, frames > 0, stride > 0 else { return .empty }
        var sum: Double = 0
        var peak: Float = 0
        var clipped = 0
        for index in 0..<frames {
            // Int32 so abs(Int16.min) cannot trap.
            let value = Float(abs(Int32(base[index * stride]))) / 32768
            sum += Double(value) * Double(value)
            if value > peak { peak = value }
            if value >= clipThreshold { clipped += 1 }
        }
        let rms = Float((sum / Double(frames)).squareRoot())
        return PCMMeasurement(rms: min(rms, 1), peak: min(peak, 1), clippedSamples: clipped, frames: frames)
    }

    /// Measures a captured buffer in whichever PCM layout the microphone negotiated:
    /// float or Int16, planar or interleaved, mono or stereo.
    static func measure(_ buffer: AVAudioPCMBuffer) -> PCMMeasurement? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        guard frames > 0, channels > 0, stride > 0 else { return nil }
        var result = PCMMeasurement.empty
        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                result = result.merged(with: measure(floats: data[channel], frames: frames, stride: stride))
            }
            return result
        }
        if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                result = result.merged(with: measure(int16: data[channel], frames: frames, stride: stride))
            }
            return result
        }
        return nil
    }
}

/// What the person should be told about the microphone signal.
enum PCMInputQuality: Equatable {
    case waiting, silent, quiet, good, clipping
}

/// Display level, six bar heights and input quality, advanced only by measured audio.
struct PCMLevelTracker: Equatable {
    static let barCount = 6
    /// RMS at or below this is drawn as an empty meter; at or above `ceilingDB` it is full.
    static let floorDB: Float = -50
    static let ceilingDB: Float = -10
    /// Seconds of audio for the meter to cover ~63% of a rise or fall.
    static let attack = 0.04
    static let release = 0.30
    /// Quality windows, in seconds of delivered audio.
    static let clipHold = 1.2
    static let silentAfter = 3.0
    static let quietAfter = 4.0
    /// Peak below this is digital silence (muted or absent input).
    static let silentPeak: Float = 0.002
    /// Peak below this is too soft for dependable recognition (about -30 dBFS).
    static let quietPeak: Float = 0.03
    /// Seconds of audio between history samples that carry level outward from the center.
    static let historyStep = 0.05
    /// Center bars use the newest level; outer bars the older history, scaled to a bell.
    static let envelope: [Float] = [1.0, 0.84, 0.62]

    private(set) var level: Float = 0
    private(set) var quality: PCMInputQuality = .waiting
    private var history: [Float] = [0, 0]
    private var sinceStep = 0.0
    private var silentFor = 0.0
    private var quietFor = 0.0
    private var clipFor = 0.0

    static func displayLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }

    /// Six bar levels, left to right, each 0...1. Symmetric: distance from center picks history age.
    var bars: [Float] {
        let ages = [level, history[0], history[1]]
        return [2, 1, 0, 0, 1, 2].map { ages[$0] * Self.envelope[$0] }
    }

    mutating func ingest(_ measurement: PCMMeasurement, duration: TimeInterval) {
        guard duration > 0, duration.isFinite else { return }
        let target = Self.displayLevel(rms: measurement.rms)
        let tau = target > level ? Self.attack : Self.release
        level += (target - level) * Float(1 - exp(-duration / tau))
        if target == 0, level < 0.01 { level = 0 }

        sinceStep += duration
        if sinceStep >= Self.historyStep {
            sinceStep = sinceStep.truncatingRemainder(dividingBy: Self.historyStep)
            history = [level, history[0]]
        }

        if measurement.clippedSamples >= 2 { clipFor = Self.clipHold }
        else { clipFor = max(0, clipFor - duration) }
        if measurement.peak >= Self.quietPeak {
            quietFor = 0; silentFor = 0
        } else {
            quietFor += duration
            silentFor = measurement.peak < Self.silentPeak ? silentFor + duration : 0
        }
        if clipFor > 0 { quality = .clipping }
        else if silentFor >= Self.silentAfter { quality = .silent }
        else if quietFor >= Self.quietAfter { quality = .quiet }
        else { quality = .good }
    }

    /// No audio arrived for `seconds` (a stall or pause): fall toward zero. Quality windows
    /// count delivered audio only, so a stall is never mistaken for a quiet room.
    mutating func decay(over seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        let factor = Float(exp(-seconds / Self.release))
        level *= factor
        history = history.map { $0 * factor }
        if level < 0.01 { level = 0 }
        history = history.map { $0 < 0.01 ? 0 : $0 }
        clipFor = max(0, clipFor - seconds)
        if clipFor == 0, quality == .clipping { quality = .good }
    }
}

struct PCMLevelSnapshot: Equatable {
    var bars: [Float]
    var level: Float
    var quality: PCMInputQuality

    static let idle = PCMLevelSnapshot(bars: Array(repeating: 0, count: PCMLevelTracker.barCount), level: 0, quality: .waiting)
}

/// Thread-safe level meter for one capture. The audio thread calls `ingest`; the UI calls
/// `snapshot`. A meter belongs to a single capture: after `finish()` late buffers from that
/// capture are dropped, so a stale tap cannot move a newer recording's bars.
final class PCMLevelMeter: @unchecked Sendable {
    /// A gap this long without a buffer starts the decay (one tap buffer is ~40 ms).
    static let staleAfter = 0.12

    private let lock = NSLock()
    private var tracker = PCMLevelTracker()
    private var paused = false
    private var finished = false
    private var lastIngest: TimeInterval?

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func ingest(_ buffer: AVAudioPCMBuffer, uptime: TimeInterval = PCMLevelMeter.now) {
        guard let measurement = PCMAmplitude.measure(buffer), buffer.format.sampleRate > 0 else { return }
        ingest(measurement, duration: Double(buffer.frameLength) / buffer.format.sampleRate, uptime: uptime)
    }

    func ingest(_ measurement: PCMMeasurement, duration: TimeInterval, uptime: TimeInterval = PCMLevelMeter.now) {
        lock.lock(); defer { lock.unlock() }
        guard !paused, !finished else { return }
        guard duration > 0, duration.isFinite, uptime.isFinite else { return }
        // snapshot decays a copy for display. Also decay the retained history across a
        // missing-audio gap, or the first quiet buffer after a stall resurrects old bars.
        if let lastIngest {
            let gap = uptime - lastIngest - duration
            if gap > Self.staleAfter { tracker.decay(over: gap) }
        }
        tracker.ingest(measurement, duration: duration)
        lastIngest = uptime
    }

    /// Zeroes the display immediately; buffers still in flight are ignored until `resume()`.
    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        paused = true
        tracker = PCMLevelTracker()
        lastIngest = nil
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        paused = false
        lastIngest = nil
    }

    /// Route or media-services reset: forget the level and quality history, keep listening.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker = PCMLevelTracker()
        lastIngest = nil
    }

    /// Terminal. Used when this capture stops, so nothing from it can update the display again.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        tracker = PCMLevelTracker()
        lastIngest = nil
    }

    func snapshot(uptime: TimeInterval = PCMLevelMeter.now) -> PCMLevelSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !paused else { return .idle }
        var value = tracker
        if let lastIngest, uptime - lastIngest > Self.staleAfter { value.decay(over: uptime - lastIngest) }
        return PCMLevelSnapshot(bars: value.bars, level: value.level, quality: value.quality)
    }
}

/// 16 kHz mono 16-bit PCM WAV header, shared by the on-device and fallback writers.
enum WAVHeader {
    static func data(bytes: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        integer(bytes + 36); data.append(Data("WAVEfmt ".utf8)); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(16000)); integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(bytes)
        return data
    }
}

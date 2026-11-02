import AVFoundation

/// Pulls the spoken answer out of a recorded video as 16 kHz mono 16-bit PCM WAV, the format the
/// existing transcription service accepts. Only this audio is uploaded; the video stays local.
enum AudioExtractor {
    static let sampleRate = 16_000
    static let maximumBytes = 10 * 1024 * 1024

    static func wav(from video: URL, to output: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw APIError(message: "This recording has no audio. Check the microphone and record again.")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { throw APIError(message: "Audio extraction is unavailable on this phone.") }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw APIError(message: reader.error?.localizedDescription ?? "The recording could not be read.")
        }
        var pcm = Data()
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = Data(count: length)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw APIError(message: "The recording audio could not be read.") }
            pcm.append(chunk)
            guard pcm.count + 44 <= maximumBytes else { throw APIError(message: "This answer is too long to score. Keep answers under five minutes.") }
        }
        if reader.status == .failed { throw APIError(message: reader.error?.localizedDescription ?? "The recording could not be read.") }
        // The transcription service rejects clips shorter than 0.3 s.
        guard pcm.count >= sampleRate * 2 * 3 / 10 else { throw APIError(message: "No answer was captured. Record again.") }
        var file = header(dataBytes: pcm.count)
        file.append(pcm)
        try file.write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return output
    }

    static func header(dataBytes: Int) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        return data
    }
}

import AVFoundation

/// Records 16 kHz mono AAC (.m4a) to one reused temp file.
final class Recorder: NSObject {
    struct Take {
        let url: URL
        let duration: TimeInterval
        /// Loudest average level seen, in dBFS. Used to skip silent takes,
        /// which transcription models tend to fill with invented text.
        let peakPower: Float
    }

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var peak: Float = -160

    /// Live input level, 0…1, about 20 times a second while recording.
    var onLevel: ((Float) -> Void)?

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-take.m4a")

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw NSError(domain: "Dictate", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法開始錄音"]) }
        recorder = r
        peak = -160
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            r.updateMeters()
            let power = r.averagePower(forChannel: 0)
            self.peak = max(self.peak, power)
            // Map -50…0 dBFS to 0…1.
            self.onLevel?(max(0, min(1, (power + 50) / 50)))
        }
    }

    @discardableResult
    func stop() -> Take? {
        meterTimer?.invalidate()
        meterTimer = nil
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        return Take(url: url, duration: duration, peakPower: peak)
    }
}

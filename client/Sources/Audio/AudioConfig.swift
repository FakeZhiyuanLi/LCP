import AVFoundation

/// The compressed speech format shared by all lecture recordings.
struct AudioConfig {
    let sampleRate: Double = 16_000
    let channelCount: Int = 1
    let bitRate: Int = 32_000

    var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
    }
}

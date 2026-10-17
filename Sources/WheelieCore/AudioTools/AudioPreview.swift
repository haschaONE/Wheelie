import Foundation

/// Temp renders for the editors' play buttons.
public enum AudioPreview {
    /// Decodes the first audio stream to something AVAudioPlayer plays (WAV, or AAC for long files).
    /// For formats AVFoundation can't open (Ogg, Opus, Matroska, ...). Returns the file written.
    @discardableResult
    public static func playableCopy(of url: URL, info: AudioInfo, in directory: URL) async throws -> URL {
        let encoding = AudioEncoding.preview(forDuration: info.duration)
        let output = directory.appendingPathComponent("playable-\(UUID().uuidString).\(encoding.fileExtension)")
        let args = AudioFFmpeg.baseArguments + ["-i", url.path, "-vn", "-map", "0:\(info.audioStreamIndex)"]
            + encoding.codecArguments + [output.path]
        try await AudioFFmpeg.run(args, output: output)
        return output
    }

    /// A fresh temp file name for a preview render.
    public static func temporaryURL(in directory: URL, prefix: String, info: AudioInfo) -> URL {
        let encoding = AudioEncoding.preview(forDuration: info.duration)
        return directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(encoding.fileExtension)")
    }
}

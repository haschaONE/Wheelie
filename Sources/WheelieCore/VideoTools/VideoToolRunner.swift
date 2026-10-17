import Foundation

/// Reads ffmpeg's `-progress` key=value stream and turns it into a 0...1 fraction.
public struct VideoToolProgressParser: Sendable {
    public let expectedDuration: Double
    private var pending = ""

    public init(expectedDuration: Double) { self.expectedDuration = expectedDuration }

    /// Feeds raw output; returns the newest fraction found in it, if any.
    public mutating func feed(_ text: String) -> Double? {
        pending += text
        var latest: Double?
        while let newline = pending.firstIndex(of: "\n") {
            let line = pending[..<newline].trimmingCharacters(in: .whitespaces)
            pending.removeSubrange(...newline)
            if let value = Self.fraction(line: line, expectedDuration: expectedDuration) { latest = value }
        }
        return latest
    }

    /// `out_time_us` / `out_time_ms` are both microseconds in ffmpeg; `progress=end` means done.
    static func fraction(line: String, expectedDuration: Double) -> Double? {
        if line == "progress=end" { return 1 }
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard expectedDuration > 0, let micro = Double(line.dropFirst(key.count)) else { return nil }
            return min(1, max(0, micro / 1_000_000 / expectedDuration))
        }
        return nil
    }
}

/// Runs ffmpeg with progress reporting and cancellation. Deletes `cleanup` files on failure.
public enum VideoToolRunner {
    public typealias Progress = @Sendable (Double) -> Void

    public static func ffmpeg(_ arguments: [String], expectedDuration: Double? = nil, cleanup: [URL] = [],
                              progress: Progress? = nil) async throws {
        guard let exe = Tools.locate("ffmpeg") else { throw ToolError.missing("ffmpeg") }
        var full = VideoToolArgs.global
        let reportsProgress = progress != nil && (expectedDuration ?? 0) > 0
        if reportsProgress { full += ["-progress", "pipe:1"] }
        full += arguments
        // Same demuxer allowlist / local-only protocols as Tools.run (see Tools.hardenFFmpegInputs).
        full = try Tools.hardenFFmpegInputs(full)
        let handle = VideoToolProcess()
        do {
            try await withTaskCancellationHandler {
                try await run(exe, full, handle: handle,
                              parser: reportsProgress ? VideoToolProgressParser(expectedDuration: expectedDuration ?? 0) : nil,
                              progress: progress)
            } onCancel: {
                handle.cancel()
            }
        } catch {
            for url in cleanup { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        progress?(1)
    }

    private static func run(_ exe: URL, _ arguments: [String], handle: VideoToolProcess,
                            parser: VideoToolProgressParser?, progress: Progress?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = exe
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let errData = VideoToolLockedBuffer()
            let progressState = VideoToolLockedParser(parser)
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty, let value = progressState.feed(String(decoding: chunk, as: UTF8.self)),
                      !handle.wasCancelled else { return }   // a stopped ffmpeg still reports "progress=end"
                progress?(value)
            }
            errPipe.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                if handle.wasCancelled {
                    cont.resume(throwing: CancellationError())
                } else if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let stderr = String(decoding: errData.value, as: UTF8.self)
                    cont.resume(throwing: ToolError.failed(tool: "ffmpeg", status: p.terminationStatus, stderr: stderr))
                }
            }
            guard handle.attach(process) else {
                cont.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}

/// The process behind a running job, so cancellation can stop it.
final class VideoToolProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// False when the job was cancelled before it started.
    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

final class VideoToolLockedBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

final class VideoToolLockedParser: @unchecked Sendable {
    private var parser: VideoToolProgressParser?
    private let lock = NSLock()
    init(_ parser: VideoToolProgressParser?) { self.parser = parser }
    func feed(_ text: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return parser?.feed(text)
    }
}

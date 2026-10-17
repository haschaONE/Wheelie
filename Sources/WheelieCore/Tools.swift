import Foundation

public enum ToolError: LocalizedError {
    case missing(String)
    case failed(tool: String, status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "\(name) not found. Install it with: brew install \(name == "cwebp" ? "webp" : name)"
        case .failed(let tool, let status, let stderr):
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            return "\(tool) exited with \(status): \(tail)"
        }
    }
}

public enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public static func locate(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in searchPaths + env {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs a tool to completion off the main thread; throws with stderr on non-zero exit.
    public static func run(_ name: String, _ arguments: [String]) async throws {
        _ = try await capture(name, arguments)
    }

    /// Like `run`, but returns stdout and stderr (ffprobe, ffmpeg loudnorm/silencedetect output, ...).
    /// `name` is looked up with `locate`, or used as-is when it is an absolute path.
    @discardableResult
    public static func capture(_ name: String, _ arguments: [String]) async throws -> (stdout: String, stderr: String) {
        let exe = name.hasPrefix("/") ? URL(fileURLWithPath: name) : locate(name)
        guard let exe, FileManager.default.isExecutableFile(atPath: exe.path) else { throw ToolError.missing(name) }
        let isFFmpeg = ["ffmpeg", "ffprobe"].contains(exe.lastPathComponent)
        let finalArguments = isFFmpeg ? try hardenFFmpegInputs(arguments) : arguments
        return try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = exe
            process.arguments = finalArguments
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            // Drain both pipes continuously so a chatty tool can't fill one and block.
            let outData = LockedData(), errData = LockedData()
            outPipe.fileHandleForReading.readabilityHandler = { outData.append($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(decoding: outData.value, as: UTF8.self)
                let stderr = String(decoding: errData.value, as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: (stdout, stderr))
                } else {
                    cont.resume(throwing: ToolError.failed(tool: exe.lastPathComponent, status: p.terminationStatus, stderr: stderr))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}

public struct UnsafeMediaInputError: LocalizedError {
    public let file: String
    public var errorDescription: String? { "\(file) is a playlist, not a media file, and was not opened." }
}

extension Tools {
    /// A file named .mp4 can really be an HLS/concat playlist that makes ffmpeg read
    /// other local files or URLs into the output. For every `-i <file>` that has no
    /// explicit `-f` from us, refuse playlist content and restrict protocols to local files.
    static func hardenFFmpegInputs(_ arguments: [String]) throws -> [String] {
        var result: [String] = []
        var explicitFormat = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-f" { explicitFormat = true }
            if arg == "-i", index + 1 < arguments.count {
                let input = arguments[index + 1]
                if !explicitFormat, FileManager.default.fileExists(atPath: input) {
                    if looksLikePlaylist(input) { throw UnsafeMediaInputError(file: (input as NSString).lastPathComponent) }
                    result += ["-protocol_whitelist", "file,pipe"]
                }
                explicitFormat = false
                result += [arg, input]
                index += 2
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    static func looksLikePlaylist(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("#extm3u") || head.hasPrefix("ffconcat") || head.hasPrefix("#ext-x-")
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

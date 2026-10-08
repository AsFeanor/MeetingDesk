import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AudioToolbox
import CryptoKit
import Darwin

/// Audio-only ScreenCaptureKit capture. Permission prompts happen only in start().
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var microphoneReceivedSamples = false
    @Published private(set) var microphoneInputDBFS: Double = -80
    @Published private(set) var microphonePeakDBFS: Double = -80
    var onFailure: ((Error) -> Void)?

    /// Recover compacted raw tracks left by a crash or a failed final export.
    static func recover(url: URL) async throws -> Double {
        try await Task.detached(priority: .userInitiated) {
            try PCMRecordingSession(recoverDestination: url).finish()
        }.value
    }

    private var stream: SCStream?
    private var output: RecorderStreamOutput?
    private var timer: Timer?
    private var isStarting = false
    private var isStopping = false
    private var failureStop: Task<Void, Never>?
    private var sessionID: UUID?

    func start(url: URL, microphoneDeviceID: String? = nil, microphoneGain: Double = 2) async throws {
        guard !isRecording, !isStarting, !isStopping, output == nil else {
            throw MeetingError.message("Önce devam eden kaydı bitirin.")
        }
        isStarting = true
        defer { isStarting = false }
        guard url.pathExtension.lowercased() == "m4a" else {
            throw MeetingError.message("Kayıt dosyası .m4a biçiminde olmalı.")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MeetingError.message("Bu kayıt dosyası zaten var. Yeni bir dosya adı seçin.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingError.message("Mikrofon izni verilmedi. Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon bölümünde Toplantı’ya izin verin.")
            }
        default:
            throw MeetingError.message("Mikrofon erişimi kapalı. Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon bölümünde Toplantı’ya izin verin.")
        }
        if let microphoneDeviceID {
            guard let device = AVCaptureDevice(uniqueID: microphoneDeviceID), device.hasMediaType(.audio) else {
                throw MeetingError.message("Seçili mikrofon şu anda bağlı değil. Mikrofon seçimini kontrol edip yeniden deneyin.")
            }
        } else if AVCaptureDevice.default(for: .audio) == nil {
            throw MeetingError.message("Kullanılabilir bir mikrofon bulunamadı. Bir mikrofon bağlayıp yeniden deneyin.")
        }
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            throw MeetingError.message("Toplantının sesini almak için sistem ses kaydı izni gerekiyor. Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı bölümünde Toplantı’ya izin verip uygulamayı yeniden açın. Görüntü kaydedilmez.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw MeetingError.message("Sistem sesi başlatılamadı. Ekran ve Sistem Sesi Kaydı iznini kontrol edip yeniden deneyin. \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            throw MeetingError.message("Sistem sesi için kullanılabilir bir ekran bulunamadı.")
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        // An explicit device stays selected; nil follows the Mac's default input.
        configuration.microphoneCaptureDeviceID = microphoneDeviceID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.showsCursor = false
        configuration.queueDepth = 3

        elapsed = 0
        systemLevel = 0
        microphoneLevel = 0
        microphoneReceivedSamples = false
        microphoneInputDBFS = -80
        microphonePeakDBFS = -80
        let sink = try RecorderStreamOutput(url: url, microphoneGain: microphoneGain)
        let identifier = UUID()
        sink.onMeters = { [weak self] system, microphone, duration, receivedMicrophone, microphoneDBFS, microphonePeak in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.sessionID == identifier else { return }
                self.systemLevel = system
                self.microphoneLevel = microphone
                self.microphoneReceivedSamples = receivedMicrophone
                self.microphoneInputDBFS = microphoneDBFS
                self.microphonePeakDBFS = microphonePeak
                self.elapsed = duration
            }
        }
        sink.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == identifier else { return }
                self.handleFailure(error)
            }
        }
        let capture = SCStream(filter: filter, configuration: configuration, delegate: sink)
        // Deliberately attach audio outputs only. No screen samples or video are saved.
        try capture.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        try capture.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        output = sink
        stream = capture
        sessionID = identifier
        do {
            try await capture.startCapture()
            if let failure = await sink.currentFailure() { throw failure }
            isRecording = true
            isPaused = false
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.output?.publishMeters() }
            }
        } catch {
            sink.markFailure(error)
            try? await capture.stopCapture()
            stream = nil
            // Keep recoverable samples, while allowing a new start after startup fails.
            await sink.closePartial()
            output = nil
            sessionID = nil
            throw MeetingError.message("Kayıt başlatılamadı. \(error.localizedDescription)")
        }
    }

    func pause() {
        guard isRecording, !isPaused, !isStopping else { return }
        output?.pause(at: recorderHostTime())
        isPaused = true
        systemLevel = 0
        microphoneLevel = 0
    }

    func resume() {
        guard isRecording, isPaused, !isStopping else { return }
        output?.resume(at: recorderHostTime())
        isPaused = false
    }

    /// This also salvages a partial recording after onFailure has fired.
    func stop() async throws -> Double {
        guard !isStarting, !isStopping, let sink = output else {
            throw MeetingError.message("Bitirilebilecek etkin bir kayıt yok.")
        }
        isStopping = true
        defer { isStopping = false }
        timer?.invalidate()
        timer = nil
        sink.freeze(at: recorderHostTime())
        if let failureStop {
            await failureStop.value
            self.failureStop = nil
        } else if let stream {
            do { try await stream.stopCapture() }
            catch { sink.markFailure(error) }
        }
        stream = nil
        isRecording = false
        isPaused = false
        systemLevel = 0
        microphoneLevel = 0
        do {
            let duration = try await sink.finish()
            elapsed = duration
            output = nil
            sessionID = nil
            return duration
        } catch {
            // The recovery folder remains on disk; do not destroy the raw tracks.
            output = nil
            sessionID = nil
            throw error
        }
    }

    private func handleFailure(_ error: Error) {
        guard output != nil, !isStarting, !isStopping, failureStop == nil else { return }
        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        systemLevel = 0
        microphoneLevel = 0
        let capture = stream
        failureStop = Task { [weak self] in
            if let capture { try? await capture.stopCapture() }
            self?.stream = nil
            self?.onFailure?(error)
        }
    }
}

private func recorderHostTime() -> Double {
    CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
}

/// Both sources use one host-clock timeline. Pauses remove the same interval from both.
struct RecorderTimeline {
    struct Pause: Codable { var start: Double; var end: Double? }
    struct Placement: Equatable { var sourceOffset: Int; var count: Int; var targetFrame: Int64 }
    let origin: Double
    var pauses: [Pause] = []

    mutating func pause(at host: Double) {
        guard pauses.last?.end != nil || pauses.isEmpty else { return }
        pauses.append(Pause(start: max(origin, host), end: nil))
    }

    mutating func resume(at host: Double) {
        guard !pauses.isEmpty, pauses[pauses.count - 1].end == nil else { return }
        pauses[pauses.count - 1].end = max(pauses[pauses.count - 1].start, host)
    }

    func duration(at host: Double) -> Double {
        let removed = pauses.reduce(0.0) { result, pause in
            result + max(0, min(host, pause.end ?? host) - pause.start)
        }
        return max(0, host - origin - removed)
    }

    func placements(hostStart: Double, frameCount: Int, sampleRate: Double) -> [Placement] {
        guard hostStart.isFinite, sampleRate > 0, frameCount > 0 else { return [] }
        var result: [Placement] = []
        var activeStart = origin
        var removed = 0.0
        // Intersect whole timestamped blocks with active intervals. Work is proportional
        // to pauses, not to every audio sample, even during a long meeting.
        func appendInterval(endingAt activeEnd: Double?) {
            let lower = max(0, Int(ceil((activeStart - hostStart) * sampleRate - 0.000001)))
            let upper = activeEnd.map { min(frameCount, Int(ceil(($0 - hostStart) * sampleRate - 0.000001))) } ?? frameCount
            guard lower < upper else { return }
            let target = Int64(((hostStart - origin - removed) * sampleRate).rounded()) + Int64(lower)
            result.append(Placement(sourceOffset: lower, count: upper - lower, targetFrame: max(0, target)))
        }
        for pause in pauses {
            appendInterval(endingAt: pause.start)
            guard let end = pause.end else { return result }
            removed += end - pause.start
            activeStart = end
        }
        appendInterval(endingAt: nil)
        return result
    }
}

enum RecorderSource: String { case system, microphone }

struct RecorderSignalMetrics {
    var frames = 0
    var squareSum = 0.0
    var peak = 0.0
    var rmsDBFS: Double { 20 * log10(max(0.0001, sqrt(squareSum / Double(max(1, frames))))) }
    var peakDBFS: Double { 20 * log10(max(0.0001, peak)) }
    var meterLevel: Double { min(1, max(0, (rmsDBFS + 55) / 55)) }

    mutating func append(_ sample: Float) {
        let value = sample.isFinite ? Double(sample) : 0
        squareSum += value * value
        peak = max(peak, abs(value))
        frames += 1
    }
}

/// A fixed microphone gain improves source balance without amplifying system audio.
/// The soft knee affects only values near overload; silence and quiet speech stay linear.
enum RecorderMix {
    static func microphoneGain(_ value: Double) -> Double {
        value.isFinite ? min(4, max(1, value)) : 2
    }

    static func sample(system: Float, microphone: Float, microphoneGain: Double) -> Float {
        let system = system.isFinite ? Double(system) : 0
        let microphone = microphone.isFinite ? Double(microphone) : 0
        let value = (system + microphone * Self.microphoneGain(microphoneGain)) * 0.7071
        let magnitude = abs(value)
        guard magnitude > 0.85 else { return Float(value) }
        let limited = 0.85 + 0.15 * tanh((magnitude - 0.85) / 0.15)
        return Float(value < 0 ? -limited : limited)
    }

    static func sourceSample(_ value: Float) -> Float {
        value.isFinite ? min(1, max(-1, value)) : 0
    }
}

/// A receipt identifies only immutable output staged by this recovery session.
/// Both a random session marker and the file's complete contents must still match.
enum RecorderPublicationIdentity {
    private static let attribute = "com.altugegesari.meetingdesk.recording-session"

    static func stamp(_ url: URL, sessionID: String) throws {
        let token = Data(sessionID.utf8)
        let status = token.withUnsafeBytes { bytes in
            setxattr(url.path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard status == 0 else {
            throw MeetingError.message("Kurtarma kaydının dosya kimliği yazılamadı (\(errno)). Ham ses korundu.")
        }
    }

    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ url: URL, sessionID: String, digest: String) throws -> Bool {
        let expected = Data(sessionID.utf8)
        let length = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard length == expected.count else { return false }
        var token = Data(count: length)
        let read = token.withUnsafeMutableBytes { bytes in
            getxattr(url.path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard read == length, token == expected else { return false }
        return try Self.digest(url) == digest
    }
}

/// AVAudioFile's format dictionary does not reliably apply encoder bit rate.
/// Set it on the native converter and synchronize the file format explicitly.
final class AACAudioFileWriter {
    let processingFormat: AVAudioFormat
    private var file: ExtAudioFileRef?

    init(url: URL, sampleRate: Double, bitRate: UInt32 = 48_000) throws {
        guard let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: 1, interleaved: false) else {
            throw MeetingError.message("AAC ses biçimi hazırlanamadı.")
        }
        processingFormat = client
        var compressed = AudioStreamBasicDescription()
        compressed.mSampleRate = sampleRate
        compressed.mFormatID = kAudioFormatMPEG4AAC
        compressed.mChannelsPerFrame = 1
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &compressed))
        var reference: ExtAudioFileRef?
        try Self.check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &compressed, nil,
                                               AudioFileFlags.eraseFile.rawValue, &reference))
        guard let reference else { throw MeetingError.message("AAC kayıt dosyası oluşturulamadı.") }
        file = reference
        do {
            var pcm = client.streamDescription.pointee
            try Self.check(ExtAudioFileSetProperty(reference, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm))
            var converter: AudioConverterRef?
            var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
            try Self.check(ExtAudioFileGetProperty(reference, kExtAudioFileProperty_AudioConverter, &converterSize, &converter))
            guard let converter else { throw MeetingError.message("AAC kodlayıcısı bulunamadı.") }
            var requestedRate = bitRate
            try Self.check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                                      UInt32(MemoryLayout<UInt32>.size), &requestedRate))
            var actualRate: UInt32 = 0
            var rateSize = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioConverterGetProperty(converter, kAudioConverterEncodeBitRate, &rateSize, &actualRate))
            guard actualRate > 0, actualRate <= bitRate else {
                throw MeetingError.message("AAC kodlayıcısı istenen dosya boyutunu sağlayamadı.")
            }
            var configuration: UnsafeRawPointer?
            try Self.check(ExtAudioFileSetProperty(reference, kExtAudioFileProperty_ConverterConfig,
                                                   UInt32(MemoryLayout<UnsafeRawPointer?>.size), &configuration))
        } catch {
            ExtAudioFileDispose(reference)
            file = nil
            throw error
        }
    }

    deinit { if let file { ExtAudioFileDispose(file) } }

    func write(from buffer: AVAudioPCMBuffer) throws {
        guard let file, buffer.format == processingFormat else {
            throw MeetingError.message("AAC kaydının ses tamponu geçersiz.")
        }
        try Self.check(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList))
    }

    func close() throws {
        guard let file else { return }
        self.file = nil
        try Self.check(ExtAudioFileDispose(file))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw MeetingError.message("AAC ses dosyası işlenemedi (\(status)).")
        }
    }
}

/// Keep resampling state between callbacks to avoid restarting the filter at each block.
final class RecorderPCMConverter {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMRecordingSession.sampleRate,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var nextOutputHost: Double = 0
    private var previousInputEnd: Double?

    func convert(_ input: AVAudioPCMBuffer, hostStart: Double) throws -> (buffer: AVAudioPCMBuffer, hostStart: Double) {
        if converter?.inputFormat != input.format || previousInputEnd.map({ abs(hostStart - $0) > 0.025 }) ?? true {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.primeMethod = .none
            nextOutputHost = hostStart
        }
        guard let converter else { throw MeetingError.message("Mikrofonun ses biçimi dönüştürülemedi.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw MeetingError.message("Ses dönüştürme tamponu hazırlanamadı.")
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard result != .error else { throw MeetingError.message("Ses dönüştürülemedi.") }
        let outputHost = nextOutputHost
        nextOutputHost += Double(output.frameLength) / format.sampleRate
        previousInputEnd = hostStart + Double(input.frameLength) / input.format.sampleRate
        return (output, outputHost)
    }
}

/// Durable sparse mono float tracks. Its caller owns the serial queue.
final class PCMRecordingSession {
    static let sampleRate = 24_000.0
    let destination: URL
    let recoveryDirectory: URL
    let microphoneGain: Double
    private let recoverySessionID: String
    private var publicationDigests: [String: String] = [:]
    private(set) var timeline: RecorderTimeline
    private(set) var lastWriteMetrics: RecorderSignalMetrics?
    private var system: FileHandle?
    private var microphone: FileHandle?
    private var systemEnd: Int64 = 0
    private var microphoneEnd: Int64 = 0
    private var frozenHost: Double?
    private var failureMessage: String?
    private var lastCheckpointHost: Double
    private var systemHasSamples = false
    private var microphoneHasSamples = false

    init(destination: URL, origin: Double, microphoneGain: Double = 1) throws {
        self.destination = destination
        self.microphoneGain = RecorderMix.microphoneGain(microphoneGain)
        recoverySessionID = UUID().uuidString
        timeline = RecorderTimeline(origin: origin)
        lastCheckpointHost = origin
        recoveryDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-recovery", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: recoveryDirectory.path) {
            // A failed start may create an empty recovery folder. Allow retry only when
            // its recognized tracks contain no audio and no other files could be lost.
            let files = Set((try? fm.contentsOfDirectory(atPath: recoveryDirectory.path)) ?? [])
            let expected = Set(["system.f32pcm", "microphone.f32pcm", "recovery.json"])
            let manifestData = try? Data(contentsOf: recoveryDirectory.appendingPathComponent("recovery.json"))
            let manifest = manifestData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            func bytes(_ name: String) -> Int64? {
                (try? fm.attributesOfItem(atPath: recoveryDirectory.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
            }
            if files == expected, manifest?["version"] as? Int == 1,
               manifest?["destination"] as? String == destination.lastPathComponent,
               bytes("system.f32pcm") == 0, bytes("microphone.f32pcm") == 0 {
                try fm.removeItem(at: recoveryDirectory)
            } else {
                throw MeetingError.message("Bu kayıt için kurtarma dosyaları zaten var: \(recoveryDirectory.path)")
            }
        }
        try fm.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let systemURL = recoveryDirectory.appendingPathComponent("system.f32pcm")
            let microphoneURL = recoveryDirectory.appendingPathComponent("microphone.f32pcm")
            guard fm.createFile(atPath: systemURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  fm.createFile(atPath: microphoneURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw MeetingError.message("Kayıt dosyaları oluşturulamadı.")
            }
            system = try FileHandle(forWritingTo: systemURL)
            microphone = try FileHandle(forWritingTo: microphoneURL)
            try checkpoint(at: origin)
        } catch {
            try? system?.close()
            try? microphone?.close()
            throw error
        }
    }

    init(recoverDestination destination: URL) throws {
        self.destination = destination
        recoveryDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-recovery", isDirectory: true)
        let data = try Data(contentsOf: recoveryDirectory.appendingPathComponent("recovery.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["version"] as? Int == 1,
              manifest["sampleRate"] as? Double == Self.sampleRate,
              manifest["channels"] as? Int == 1 else {
            throw MeetingError.message("Kurtarma kaydının ses biçimi tanınmadı.")
        }
        timeline = RecorderTimeline(origin: 0)
        lastCheckpointHost = 0
        let fm = FileManager.default
        let systemURL = recoveryDirectory.appendingPathComponent("system.f32pcm")
        let microphoneURL = recoveryDirectory.appendingPathComponent("microphone.f32pcm")
        let systemBytes = (try fm.attributesOfItem(atPath: systemURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let microphoneBytes = (try fm.attributesOfItem(atPath: microphoneURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        systemEnd = systemBytes / Int64(MemoryLayout<Float>.size)
        microphoneEnd = microphoneBytes / Int64(MemoryLayout<Float>.size)
        systemHasSamples = systemEnd > 0
        microphoneHasSamples = microphoneEnd > 0
        // Sample lengths include everything written since the last manifest checkpoint.
        frozenHost = max(manifest["duration"] as? Double ?? 0, Double(max(systemEnd, microphoneEnd)) / Self.sampleRate)
        failureMessage = manifest["failure"] as? String
        // Version 1 recordings made before source balance was added retain their mix.
        microphoneGain = RecorderMix.microphoneGain(manifest["microphoneGain"] as? Double ?? 1)
        recoverySessionID = (manifest["recoverySessionID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
        publicationDigests = manifest["publicationDigests"] as? [String: String] ?? [:]
    }

    deinit { try? system?.close(); try? microphone?.close() }

    func pause(at host: Double) throws { timeline.pause(at: host); try checkpoint(at: host) }
    func resume(at host: Double) throws { timeline.resume(at: host); try checkpoint(at: host) }
    func duration(at host: Double) -> Double { timeline.duration(at: frozenHost ?? host) }

    func freeze(at host: Double) throws {
        if frozenHost == nil { frozenHost = host }
        try checkpoint(at: frozenHost ?? host)
    }

    func markFailure(_ error: Error, at host: Double) {
        failureMessage = error.localizedDescription
        if frozenHost == nil { frozenHost = host }
        try? checkpoint(at: frozenHost ?? host)
    }

    func write(_ samples: UnsafeBufferPointer<Float>, hostStart: Double, source: RecorderSource) throws {
        lastWriteMetrics = nil
        guard !samples.isEmpty else { return }
        // stopCapture can flush callbacks that were captured before the stop button.
        let usableCount = frozenHost.map { min(samples.count, max(0, Int(ceil(($0 - hostStart) * Self.sampleRate)))) } ?? samples.count
        let positions = timeline.placements(hostStart: hostStart, frameCount: usableCount, sampleRate: Self.sampleRate)
        guard let handle = source == .system ? system : microphone else {
            throw MeetingError.message("Kayıt dosyası kapanmış.")
        }
        var end = source == .system ? systemEnd : microphoneEnd
        var metrics = RecorderSignalMetrics()
        for position in positions {
            // Late or overlapping callbacks never append the same source twice.
            let trim = Int(max(0, end - position.targetFrame))
            guard trim < position.count else { continue }
            let target = position.targetFrame + Int64(trim)
            let offset = position.sourceOffset + trim
            let count = position.count - trim
            try handle.seek(toOffset: UInt64(target) * UInt64(MemoryLayout<Float>.size))
            let data = Data(bytes: samples.baseAddress!.advanced(by: offset), count: count * MemoryLayout<Float>.size)
            try handle.write(contentsOf: data)
            for index in offset..<(offset + count) { metrics.append(samples[index]) }
            end = target + Int64(count)
            if source == .system { systemHasSamples = true } else { microphoneHasSamples = true }
        }
        if source == .system { systemEnd = end } else { microphoneEnd = end }
        if metrics.frames > 0 { lastWriteMetrics = metrics }
        let now = recorderHostTime()
        if now - lastCheckpointHost >= 5 { try checkpoint(at: now) }
    }

    func closePartial() throws {
        try checkpoint(at: frozenHost ?? recorderHostTime())
        try system?.close()
        try microphone?.close()
        system = nil
        microphone = nil
    }

    /// Checkpoint ownership before a move, so a crash during publication is retryable.
    func recordPublication(pending: URL, final: URL) throws {
        let stem = destination.deletingPathExtension().lastPathComponent
        let names = Set([destination.lastPathComponent, "\(stem)-system.m4a", "\(stem)-microphone.m4a"])
        guard pending.deletingLastPathComponent().standardizedFileURL == recoveryDirectory.standardizedFileURL,
              final.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL,
              names.contains(final.lastPathComponent),
              !FileManager.default.fileExists(atPath: final.path) else {
            throw MeetingError.message("Kurtarma kaydının çıktı yolu geçersiz veya zaten dolu. Mevcut dosyalar korundu.")
        }
        try RecorderPublicationIdentity.stamp(pending, sessionID: recoverySessionID)
        publicationDigests[final.lastPathComponent] = try RecorderPublicationIdentity.digest(pending)
        try checkpoint(at: frozenHost ?? recorderHostTime())
    }

    func ownsPublishedFile(_ url: URL) throws -> Bool {
        guard let digest = publicationDigests[url.lastPathComponent] else { return false }
        return try RecorderPublicationIdentity.matches(url, sessionID: recoverySessionID, digest: digest)
    }

    func finish() throws -> Double {
        let duration = self.duration(at: recorderHostTime())
        try closePartial()
        guard systemHasSamples || microphoneHasSamples else {
            throw MeetingError.message("Ses örneği alınamadı. Mikrofon ve sistem sesi izinlerini kontrol edin. Kurtarma dosyaları: \(recoveryDirectory.path)")
        }
        // Pad missing callbacks with actual silence rather than shortening either source.
        let frames = max(Int64(ceil(duration * Self.sampleRate)), max(systemEnd, microphoneEnd))
        let fm = FileManager.default
        let stem = destination.deletingPathExtension().lastPathComponent
        let systemDestination = destination.deletingLastPathComponent().appendingPathComponent("\(stem)-system.m4a")
        let microphoneDestination = destination.deletingLastPathComponent().appendingPathComponent("\(stem)-microphone.m4a")
        let publications = [
            (pending: recoveryDirectory.appendingPathComponent("mixed.m4a"), final: destination),
            (pending: recoveryDirectory.appendingPathComponent("system.m4a"), final: systemDestination),
            (pending: recoveryDirectory.appendingPathComponent("microphone.m4a"), final: microphoneDestination)
        ]
        var ownedFiles = Set<URL>()
        for publication in publications where fm.fileExists(atPath: publication.final.path) {
            guard try ownsPublishedFile(publication.final) else {
                throw MeetingError.message("Ses dosyası zaten var ve bu kurtarma kaydına ait değil veya değişmiş. Mevcut kayıt ve ham kurtarma dosyaları korundu.")
            }
            ownedFiles.insert(publication.final)
        }
        for publication in publications { try? fm.removeItem(at: publication.pending) }
        let encoded = try AACAudioFileWriter(url: publications[0].pending, sampleRate: Self.sampleRate, bitRate: 48_000)
        let encodedSystem = try AACAudioFileWriter(url: publications[1].pending, sampleRate: Self.sampleRate, bitRate: 48_000)
        let encodedMicrophone = try AACAudioFileWriter(url: publications[2].pending, sampleRate: Self.sampleRate, bitRate: 48_000)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw MeetingError.message("Ses dosyası hazırlanamadı.")
        }
        let systemReader = try FileHandle(forReadingFrom: recoveryDirectory.appendingPathComponent("system.f32pcm"))
        let microphoneReader = try FileHandle(forReadingFrom: recoveryDirectory.appendingPathComponent("microphone.f32pcm"))
        defer { try? systemReader.close(); try? microphoneReader.close() }
        var offset: Int64 = 0
        while offset < frames {
            let count = Int(min(8192, frames - offset))
            let systemSamples = try readFloats(systemReader, count: count)
            let microphoneSamples = try readFloats(microphoneReader, count: count)
            buffer.frameLength = AVAudioFrameCount(count)
            let mixed = buffer.floatChannelData![0]
            for index in 0..<count {
                mixed[index] = RecorderMix.sample(system: systemSamples[index], microphone: microphoneSamples[index],
                                                  microphoneGain: microphoneGain)
            }
            try encoded.write(from: buffer)
            // Keep both original source levels. Future balance corrections do not need
            // the already mixed audio, nor do they amplify the other participant.
            for index in 0..<count { mixed[index] = RecorderMix.sourceSample(systemSamples[index]) }
            try encodedSystem.write(from: buffer)
            for index in 0..<count { mixed[index] = RecorderMix.sourceSample(microphoneSamples[index]) }
            try encodedMicrophone.write(from: buffer)
            offset += Int64(count)
        }
        try encoded.close() // Flush all three files before publishing any of them.
        try encodedSystem.close()
        try encodedMicrophone.close()
        for publication in publications {
            let checkedURL = ownedFiles.contains(publication.final) ? publication.final : publication.pending
            if ownedFiles.contains(publication.final), try !ownsPublishedFile(publication.final) {
                throw MeetingError.message("Kurtarma sırasında kaynak ses dosyası değişti. Mevcut dosyalar ve ham ses korundu.")
            }
            let check = try AVAudioFile(forReading: checkedURL)
            guard check.length == frames else { throw MeetingError.message("Oluşturulan ses dosyasının süresi eksik veya geçersiz.") }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: publication.pending.path)
            if !ownedFiles.contains(publication.final) {
                try recordPublication(pending: publication.pending, final: publication.final)
            }
        }
        var published: [URL] = []
        do {
            // Publish sources first, then the main file visible to the meeting library.
            for publication in [publications[1], publications[2], publications[0]] where !ownedFiles.contains(publication.final) {
                try fm.moveItem(at: publication.pending, to: publication.final)
                published.append(publication.final)
            }
        } catch {
            // Roll back only files created by this attempt. The raw sources stay intact.
            for url in published where (try? ownsPublishedFile(url)) == true { try? fm.removeItem(at: url) }
            throw error
        }
        // Delete raw recovery only after the mixed file and both sources are readable.
        try? fm.removeItem(at: recoveryDirectory)
        return Double(frames) / Self.sampleRate
    }

    private func readFloats(_ handle: FileHandle, count: Int) throws -> [Float] {
        let data = try handle.read(upToCount: count * MemoryLayout<Float>.size) ?? Data()
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBytes { destination in
            _ = data.copyBytes(to: destination, count: data.count)
        }
        return result
    }

    private func checkpoint(at host: Double) throws {
        try system?.synchronize()
        try microphone?.synchronize()
        let manifest: [String: Any] = [
            "version": 1, "sampleRate": Self.sampleRate, "channels": 1,
            "format": "little-endian float32 PCM", "destination": destination.lastPathComponent,
            "duration": duration(at: host), "systemFrames": systemEnd,
            "microphoneFrames": microphoneEnd,
            "microphoneGain": microphoneGain,
            "recoverySessionID": recoverySessionID,
            "publicationDigests": publicationDigests,
            "systemReceived": systemHasSamples, "microphoneReceived": microphoneHasSamples,
            "lastSavedAt": ISO8601DateFormatter().string(from: Date()),
            "failure": failureMessage ?? ""
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: recoveryDirectory.appendingPathComponent("recovery.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryDirectory.appendingPathComponent("recovery.json").path)
        lastCheckpointHost = host
    }
}

private final class RecorderStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "MeetingDesk.audio.processing", qos: .userInitiated)
    var onMeters: ((Double, Double, Double, Bool, Double, Double) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let session: PCMRecordingSession
    private var failed = false
    private var firstFailure: Error?
    private var accepting = true
    private var systemLevel = 0.0
    private var microphoneLevel = 0.0
    private var lastSystemHost = 0.0
    private var lastMicrophoneHost = 0.0
    private var microphoneReceivedSamples = false
    private var microphoneInputDBFS = -80.0
    private var microphonePeakDBFS = -80.0
    private let systemConverter = RecorderPCMConverter()
    private let microphoneConverter = RecorderPCMConverter()

    init(url: URL, microphoneGain: Double) throws {
        session = try PCMRecordingSession(destination: url, origin: recorderHostTime(), microphoneGain: microphoneGain)
        super.init()
    }

    func pause(at host: Double) {
        queue.async { self.perform { try self.session.pause(at: host) }; self.systemLevel = 0; self.microphoneLevel = 0 }
    }
    func resume(at host: Double) { queue.async { self.perform { try self.session.resume(at: host) } } }
    func freeze(at host: Double) {
        queue.async { self.perform { try self.session.freeze(at: host) } }
    }
    func markFailure(_ error: Error) { queue.async { self.fail(error) } }
    func currentFailure() async -> Error? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.firstFailure) }
        }
    }
    func publishMeters() {
        queue.async {
            let now = recorderHostTime()
            let pauses = self.session.timeline.pauses
            let paused = !pauses.isEmpty && pauses.last?.end == nil
            let system = paused || now - self.lastSystemHost > 0.5 ? 0 : self.systemLevel
            let microphone = paused || now - self.lastMicrophoneHost > 0.5 ? 0 : self.microphoneLevel
            let microphoneDBFS = paused || now - self.lastMicrophoneHost > 0.5 ? -80 : self.microphoneInputDBFS
            self.onMeters?(system, microphone, self.session.duration(at: now), self.microphoneReceivedSamples,
                           microphoneDBFS, self.microphonePeakDBFS)
        }
    }
    func closePartial() async {
        await withCheckedContinuation { continuation in
            queue.async { try? self.session.closePartial(); continuation.resume() }
        }
    }
    func finish() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.accepting = false
                do { continuation.resume(returning: try self.session.finish()) }
                catch {
                    continuation.resume(throwing: MeetingError.message("Ses dosyası tamamlanamadı. Ham kayıt korundu: \(self.session.recoveryDirectory.path). \(error.localizedDescription)"))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, !failed, CMSampleBufferDataIsReady(sampleBuffer),
              type == .audio || type == .microphone else { return }
        perform {
            let source: RecorderSource = type == .audio ? .system : .microphone
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let now = recorderHostTime()
            guard pts.isFinite, abs(pts - now) < 30 else {
                throw MeetingError.message("Ses kaynaklarının zaman damgaları eşleşmedi; kayıt güvenli biçimde durduruldu.")
            }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            guard count > 0,
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
            input.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
            guard status == noErr else { throw MeetingError.message("Ses örneği okunamadı (\(status)).") }
            let converter = source == .system ? systemConverter : microphoneConverter
            let result = try converter.convert(input, hostStart: pts)
            let converted = result.buffer
            guard converted.frameLength > 0, let data = converted.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: data, count: Int(converted.frameLength))
            try session.write(samples, hostStart: result.hostStart, source: source)
            // Paused, overlapping, or post-stop samples were not saved and must not
            // validate the microphone or hide a quiet input warning.
            guard let metrics = session.lastWriteMetrics else { return }
            let dbfs = metrics.rmsDBFS
            let level = metrics.meterLevel
            if source == .system { systemLevel = level; lastSystemHost = now }
            else {
                microphoneLevel = level
                lastMicrophoneHost = now
                microphoneReceivedSamples = true
                microphoneInputDBFS = dbfs
                microphonePeakDBFS = max(microphonePeakDBFS, metrics.peakDBFS)
            }
        }
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        firstFailure = error
        accepting = false
        session.markFailure(error, at: recorderHostTime())
        onFailure?(MeetingError.message("Kayıt durdu: \(error.localizedDescription) Ham kayıt korundu: \(session.recoveryDirectory.path)"))
    }
}

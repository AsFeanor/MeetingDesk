import SwiftUI
import AVFoundation

enum MicrophoneCheckAssessment: Equatable {
    case noInput, quiet, clipping, ready
    static func assess(received: Bool, peakDBFS: Double) -> Self {
        guard received, peakDBFS.isFinite else { return .noInput }
        if peakDBFS < -42 { return .quiet }
        if peakDBFS >= -1 { return .clipping }
        return .ready
    }
    var message: String {
        switch self {
        case .noInput: return "Mikrofondan ses alınmadı. Seçili mikrofonu ve mikrofon iznini kontrol et."
        case .quiet: return "Sesin çok düşük. Mikrofona yaklaş, giriş sesini veya güçlendirmeyi artırıp tekrar dene."
        case .clipping: return "Ses çok yüksek. Giriş sesini azaltıp tekrar dene."
        case .ready: return "Mikrofondan ses alındı. Kaydı dinleyip sesinin netliğini kontrol et."
        }
    }
}

@MainActor
final class MicrophoneCheck: ObservableObject {
    let recorder = AudioRecorder()
    @Published private(set) var isWorking = false
    @Published private(set) var remaining = 10
    @Published private(set) var assessment: MicrophoneCheckAssessment?
    @Published private(set) var previewURL: URL?
    @Published private(set) var errorMessage: String?
    private var folder: URL?
    private var captureTask: Task<Void, Never>?
    private var player: AVAudioPlayer?

    func start(deviceID: String?, gain: Double) {
        guard !isWorking else { return }
        cleanupFiles()
        assessment = nil; errorMessage = nil; remaining = 10; isWorking = true
        captureTask = Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Toplanti-SesDenemesi-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                self.folder = folder
                let mixed = folder.appendingPathComponent("check.m4a")
                try await recorder.start(url: mixed, microphoneDeviceID: deviceID, microphoneGain: gain)
                for second in (1...10).reversed() {
                    remaining = second
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Task.checkCancellation()
                    if let errorMessage { throw MeetingError.message(errorMessage) }
                }
                let result = MicrophoneCheckAssessment.assess(received: recorder.microphoneReceivedSamples, peakDBFS: recorder.microphonePeakDBFS)
                _ = try await recorder.stop()
                try Task.checkCancellation()
                let mic = folder.appendingPathComponent("check-microphone.m4a")
                let preview = folder.appendingPathComponent("microphone-preview.caf")
                try Self.makePreview(input: mic, output: preview, gain: gain)
                previewURL = preview; assessment = result; remaining = 0
            } catch {
                _ = try? await recorder.stop()
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                cleanupFiles()
            }
            isWorking = false; captureTask = nil
        }
        recorder.onFailure = { [weak self] error in self?.errorMessage = error.localizedDescription }
    }

    func play() {
        guard let previewURL, !isWorking else { return }
        do { player?.stop(); player = try AVAudioPlayer(contentsOf: previewURL); player?.play() }
        catch { errorMessage = "Deneme kaydı dinlenemedi: \(error.localizedDescription)" }
    }

    func close() async {
        captureTask?.cancel()
        await captureTask?.value
        cleanupFiles()
    }

    private func cleanupFiles() {
        player?.stop(); player = nil; previewURL = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    static func makePreview(input: URL, output: URL, gain: Double) throws {
        try MicrophoneAudioPreparation.makePreview(input: input, output: output, gain: gain)
    }

}

struct MicrophoneCheckView: View {
    @ObservedObject var store: AppStore
    @StateObject private var check = MicrophoneCheck()
    @State private var closing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sesini kontrol et").font(.title2.weight(.semibold))
            Text("\(store.selectedMicrophoneName) · \(Int(store.microphoneGain))× güçlendirme").font(.callout).foregroundStyle(.secondary)
            Text("Denemeyi başlatıp 10 saniye konuş. Sonra yalnız mikrofonunu dinleyerek sesinin netliğini kontrol et.")
            if check.isWorking { MicrophoneCheckMeter(recorder: check.recorder, remaining: check.remaining) }
            if let assessment = check.assessment {
                Label(assessment.message, systemImage: assessment == .ready ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(assessment == .ready ? Color.primary : Color.orange)
            }
            if let error = check.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            Text("Deneme toplantı arşivine eklenmez. Kapatınca geçici kayıtlar silinir.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Kapat") {
                    closing = true
                    Task { await check.close(); store.showMicrophoneCheck = false }
                }.disabled(closing)
                Spacer()
                if check.previewURL != nil { Button("Sesimi dinle") { check.play() }.disabled(closing) }
                Button(check.assessment == nil ? "10 saniyelik deneme başlat" : "Tekrar dene") {
                    store.stopPlayback()
                    check.start(deviceID: store.microphoneDeviceID.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : store.microphoneDeviceID, gain: store.microphoneGain)
                }.buttonStyle(.borderedProminent).disabled(check.isWorking || closing)
            }
        }.padding(28).frame(width: 540)
            .interactiveDismissDisabled(true)
            .onDisappear { Task { await check.close(); store.showMicrophoneCheck = false } }
    }
}

private struct MicrophoneCheckMeter: View {
    @ObservedObject var recorder: AudioRecorder
    let remaining: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recorder.isRecording ? "Konuşabilirsin · \(remaining) saniye kaldı" : "Mikrofon hazırlanıyor…").font(.callout)
            ProgressView(value: recorder.microphoneLevel).accessibilityLabel("Mikrofon ses seviyesi")
        }
    }
}

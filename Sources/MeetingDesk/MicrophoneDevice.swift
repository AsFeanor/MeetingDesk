import AVFoundation

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let name: String

    static func available() -> [MicrophoneDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        var seen = Set<String>()
        return discovery.devices.filter { seen.insert($0.uniqueID).inserted }
            .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum PlaybackSource: String, CaseIterable, Identifiable {
    case mixed, microphone, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mixed: return "Birleşik kayıt"
        case .microphone: return "Yalnız mikrofon"
        case .system: return "Yalnız toplantı sesi"
        }
    }
}

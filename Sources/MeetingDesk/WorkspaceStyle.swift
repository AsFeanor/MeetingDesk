import AppKit
import SwiftUI

enum WorkspaceAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "meetingdesk.appearance"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Sistem"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Shared native colors resolve against the hosting window's appearance.
enum WorkspaceStyle {
    static let canvas = adaptive("canvas", light: 0xF8F8F4, dark: 0x171B1A)
    static let sidebar = adaptive("sidebar", light: 0xF0F2EC, dark: 0x121615)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x1D2321)
    static let elevated = adaptive("elevated", light: 0xE9EEE8, dark: 0x28312D)
    static let border = adaptive("border", light: 0xDDE3DB, dark: 0x35413A)
    static let ink = adaptive("ink", light: 0x202B25, dark: 0xEDF2EC)
    static let muted = adaptive("muted", light: 0x657168, dark: 0xA0AFA4)
    static let accent = adaptive("accent", light: 0x23664F, dark: 0x96D8B4)
    static let recording = adaptive("recording", light: 0xB54A35, dark: 0xF18B72)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("MeetingDesk.workspace.\(name)")) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                           green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255, alpha: 1)
        })
    }
}

struct WorkspacePrimaryButtonStyle: ButtonStyle {
    var tint: Color = WorkspaceStyle.accent

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceButtonSurface(label: configuration.label, isPressed: configuration.isPressed, prominent: true, tint: tint)
    }
}

struct WorkspaceQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceButtonSurface(label: configuration.label, isPressed: configuration.isPressed, prominent: false)
    }
}

private struct WorkspaceButtonSurface<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let prominent: Bool
    var tint: Color = WorkspaceStyle.accent
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var foreground: Color {
        prominent ? (scheme == .dark ? Color(red: 0.08, green: 0.18, blue: 0.13) : .white) : WorkspaceStyle.ink
    }

    var body: some View {
        label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? tint : (hovered ? WorkspaceStyle.elevated : WorkspaceStyle.surface))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : WorkspaceStyle.border, lineWidth: 1)
            }
            .brightness(prominent && hovered ? 0.035 : 0)
            .opacity(enabled ? (isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
            .onHover { hovered = $0 }
    }
}

struct WorkspaceBadge: View {
    let text: String
    let symbol: String
    var color: Color = WorkspaceStyle.accent

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkspaceAvatar: View {
    let name: String
    var size: CGFloat = 28

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased(with: Locale(identifier: "tr_TR"))
    }

    var body: some View {
        Text(initials)
            .font(.system(size: max(9, size * 0.32), weight: .semibold, design: .rounded))
            .foregroundStyle(WorkspaceStyle.accent)
            .frame(width: size, height: size)
            .background(WorkspaceStyle.accent.opacity(0.11), in: Circle())
            .overlay(Circle().strokeBorder(WorkspaceStyle.accent.opacity(0.13), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Konuşmacı" : name)
    }
}

/// A segmented level meter, not a synthetic waveform. Each illuminated segment
/// represents the measured level supplied by the recorder for its own channel.
struct AudioLevelRibbon: View {
    let microphone: Double
    let system: Double
    let paused: Bool

    var body: some View {
        HStack(spacing: 18) {
            AudioLevelChannel(label: "Mikrofon", symbol: "mic.fill", value: microphone, paused: paused)
            AudioLevelChannel(label: "Toplantı", symbol: "speaker.wave.2.fill", value: system, paused: paused)
        }
    }
}

private struct AudioLevelChannel: View {
    let label: String
    let symbol: String
    let value: Double
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: Double { paused || !value.isFinite ? 0 : min(1, max(0, value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WorkspaceStyle.muted)
            HStack(spacing: 2) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / 18 < level ? WorkspaceStyle.accent : WorkspaceStyle.border.opacity(0.75))
                        .frame(width: 3, height: 12)
                }
            }
            .animation(reduceMotion || paused ? nil : .easeOut(duration: 0.1), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) ses seviyesi")
        .accessibilityValue(paused ? "Duraklatıldı" : "Yüzde \(Int(level * 100))")
    }
}

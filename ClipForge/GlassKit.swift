import SwiftUI
import AVFoundation

enum Theme {
    static let accent = Color(red: 0.62, green: 0.40, blue: 1.0)
}

func clock(_ t: Double) -> String {
    let s = max(0, Int(t))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func glassStyle(tint: Color?, interactive: Bool) -> Glass {
    var g = Glass.regular
    if let tint { g = g.tint(tint) }
    if interactive { g = g.interactive() }
    return g
}
#endif

extension View {
    /// Liquid Glass on iOS 26 (when built with Xcode 26), frosted material everywhere else.
    @ViewBuilder
    func glass(_ radius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(glassStyle(tint: tint, interactive: interactive), in: .rect(cornerRadius: radius))
        } else {
            self.frostedGlass(radius, tint)
        }
        #else
        self.frostedGlass(radius, tint)
        #endif
    }

    func frostedGlass(_ radius: CGFloat, _ tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background((tint ?? .clear).opacity(0.35), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.07)
            Circle().fill(Color(red: 0.55, green: 0.30, blue: 1.0).opacity(0.45))
                .frame(width: 320, height: 320).blur(radius: 90).offset(x: -120, y: -260)
            Circle().fill(Color(red: 0.10, green: 0.80, blue: 1.0).opacity(0.30))
                .frame(width: 300, height: 300).blur(radius: 100).offset(x: 140, y: 120)
            Circle().fill(Color(red: 1.0, green: 0.30, blue: 0.60).opacity(0.25))
                .frame(width: 260, height: 260).blur(radius: 90).offset(x: -100, y: 330)
        }
        .ignoresSafeArea()
    }
}

struct Chip: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.black : Color.white)
            .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

struct BusyOverlay: View {
    let text: String
    let progress: Double?
    let onCancel: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(Theme.accent).frame(width: 200)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text(text).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                if let onCancel {
                    Button("Cancel", action: onCancel).font(.system(size: 14, weight: .semibold))
                }
            }
            .padding(24)
            .frame(maxWidth: 300)
            .glass(28)
        }
    }
}

struct SettingsSheet: View {
    @AppStorage("anthropicKey") private var key = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude API key (optional)")
                } footer: {
                    Text("Used only for “AI rank”. Only transcript text is sent to api.anthropic.com, never video or audio. The key is stored on this phone.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

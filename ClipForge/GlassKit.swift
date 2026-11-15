import SwiftUI
import AVFoundation

/// ClipForge look: a dark "control room" — graphite surfaces, hairline borders, one signal-lime
/// accent, monospaced timecodes and small uppercase labels. Glass is only used for chrome that
/// floats over video.
enum Theme {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let surface = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let raised = Color(red: 0.13, green: 0.13, blue: 0.145)
    static let line = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let accent = Color(red: 0.84, green: 1.0, blue: 0.25)
    static let hot = Color(red: 1.0, green: 0.36, blue: 0.24)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
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

    /// Flat panel used for the editor's tool areas.
    func panel(_ radius: CGFloat = 18) -> some View {
        self
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Small uppercase section label: "CAPTIONS · 3 WORDS".
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.faint)
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
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(selected ? Color.black : Color.white)
            .background(selected ? Theme.accent : Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Segmented control in house style (the system one looks generic on this palette).
struct Segments<T: Hashable & Identifiable>: View {
    let items: [T]
    let label: (T) -> String
    @Binding var value: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { it in
                Button { withAnimation(.snappy(duration: 0.2)) { value = it } } label: {
                    Text(label(it))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .foregroundStyle(value == it ? Color.black : Theme.dim)
                        .background { if value == it { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent) } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Inline status for a background job: label, detail and a thin progress line.
struct JobRow: View {
    let job: Job
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PulseDot()
                Text(job.title).font(.system(size: 12.5, weight: .semibold))
                if !job.detail.isEmpty { Text(job.detail).font(Theme.mono(11)).foregroundStyle(Theme.dim) }
                Spacer()
                if let p = job.progress { Text("\(Int(p * 100))%").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.accent) }
                if let onCancel {
                    Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    if let p = job.progress {
                        Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * min(max(p, 0), 1)))
                    } else {
                        IndeterminateBar()
                    }
                }
            }
            .frame(height: 3)
        }
    }
}

struct PulseDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.3)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}

struct IndeterminateBar: View {
    @State private var x: CGFloat = -0.3
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Theme.accent)
                .frame(width: g.size.width * 0.3)
                .offset(x: g.size.width * x)
                .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { x = 0.7 } }
        }
        .clipShape(Capsule())
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

struct SettingsSheet: View {
    @AppStorage("anthropicKey") private var key = ""
    @AppStorage("helperURL") private var helperURL = ""
    @AppStorage("helperKey") private var helperKey = ""
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
                    Text("Turns on: Claude picking and cutting the shorts with proper context, hooks, post titles and hashtags, and caption fixes. Only transcript text is sent to api.anthropic.com, never video or audio. Typical cost is well under one US cent per stream with Claude Haiku. The key stays on this phone.")
                }
                Section {
                    TextField("http://192.168.1.5:8790", text: $helperURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Helper key", text: $helperKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("YouTube links (optional PC helper)")
                } footer: {
                    Text("Twitch and Kick links download on the phone and need nothing here. YouTube blocks app downloads, so it needs helper/clipforge_helper.py running on a computer (it uses yt-dlp). Paste the address and key it prints; phone and computer on the same Wi-Fi.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }
}

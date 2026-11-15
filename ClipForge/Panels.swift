import SwiftUI

// MARK: Moments

struct MomentsPanel: View {
    @Bindable var model: EditorModel
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Source", selection: $model.source) {
                ForEach(MomentSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Chip(title: "Analyze speech", icon: "waveform.and.mic", selected: false) { model.analyzeSpeech() }
                Chip(title: "AI rank", icon: "sparkles", selected: false) { Task { await model.aiRank() } }
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "key.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }

            let list = model.visibleMoments
            if list.isEmpty {
                Text(model.source == .speech
                     ? "Tap “Analyze speech” to transcribe the loudest moments and score them by what was said."
                     : "No moments found.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(list) { m in
                            MomentCard(m: m, selected: m.id == model.selectedID) { model.select(m) }
                        }
                    }
                }
            }
        }
    }
}

struct MomentCard: View {
    let m: Moment
    let selected: Bool
    let action: () -> Void

    private var badge: Color {
        m.combined > 0.7 ? .orange : (m.combined > 0.4 ? .yellow : Color.white.opacity(0.7))
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(clock(m.start)).font(.system(size: 13, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("\(Int(m.combined * 100))")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(badge, in: Capsule())
                }
                Text(m.hook.isEmpty ? (m.transcript.isEmpty ? "Loud moment · \(Int(m.end - m.start)) s" : m.transcript) : m.hook)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if m.loud > 0.6 { Image(systemName: "bolt.fill") }
                    if m.text != nil { Image(systemName: "text.bubble.fill") }
                    if m.ai != nil { Image(systemName: "sparkles") }
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(width: 178, height: 112, alignment: .topLeading)
            .background(Color.white.opacity(selected ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Layout

struct LayoutPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Layout", selection: model.bind(\.layout)) {
                ForEach(ReelLayout.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.style.layout == .fit {
                HStack(spacing: 8) {
                    Text("Background").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    ForEach(ReelBackground.allCases) { b in
                        Chip(title: b.rawValue, selected: model.style.background == b) {
                            model.style.background = b
                            model.styleChanged()
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crop position").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    Slider(value: model.bind(\.panX), in: 0...1).tint(Theme.accent)
                }
            }

            Toggle("Remove silences", isOn: Binding(
                get: { model.removeSilence },
                set: { model.removeSilence = $0; model.scheduleRebuild() }))
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
    }
}

// MARK: Captions

struct CaptionsPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Captions", isOn: model.bind(\.captionsOn))
                    .font(.system(size: 15, weight: .semibold))

                if model.style.captionsOn {
                    HStack(spacing: 8) {
                        ForEach(CaptionStyleKind.allCases) { k in
                            Chip(title: k.rawValue, selected: model.style.captionStyle == k) {
                                model.style.captionStyle = k
                                model.styleChanged()
                            }
                        }
                        Spacer()
                        ForEach(0..<CaptionRenderer.palette.count, id: \.self) { i in
                            Circle()
                                .fill(Color(CaptionRenderer.palette[i]))
                                .frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.white, lineWidth: model.style.accent == i ? 3 : 0))
                                .onTapGesture { model.style.accent = i; model.styleChanged() }
                        }
                    }

                    HStack {
                        Picker("Language", selection: Binding(
                            get: { model.language }, set: { model.setLanguage($0) })) {
                            ForEach(languages) { Text($0.name).tag($0.code) }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        Toggle("HQ model", isOn: $model.accurateModel)
                            .toggleStyle(.switch)
                            .fixedSize()
                            .font(.system(size: 13))
                    }

                    HStack {
                        Chip(title: model.captionsReady ? "Re-generate" : "Generate captions",
                             icon: "captions.bubble", selected: !model.captionsReady) {
                            Task { await model.generateCaptions() }
                        }
                        Text(model.captionsReady ? "Ready for this clip" : "Not transcribed yet")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }
}

// MARK: Effects

struct EffectsPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Punch-in zoom on shouts", isOn: model.bind(\.punch))
            Toggle("Hype meter", isOn: model.bind(\.hype))
            HStack {
                TextField("Hook title (first 2.5 s)", text: model.bind(\.hook))
                    .textFieldStyle(.roundedBorder)
                if let m = model.moments.first(where: { $0.id == model.selectedID }), !m.hook.isEmpty {
                    Chip(title: "AI hook", icon: "sparkles", selected: false) {
                        model.style.hook = m.hook
                        model.styleChanged()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 15, weight: .semibold))
    }
}

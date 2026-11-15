import SwiftUI
import PhotosUI

// MARK: Moments

struct MomentsPanel: View {
    @Bindable var model: EditorModel
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Segments(items: MomentSource.allCases, label: { $0.rawValue }, value: $model.source)
                    .frame(maxWidth: 230)
                Spacer()
                if model.selecting {
                    Button("Cancel") { model.selecting = false; model.picked = [] }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
                } else {
                    Button { model.selecting = true } label: {
                        Image(systemName: "checklist").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
            }

            if let job = model.analysisJob {
                JobRow(job: job, onCancel: { model.cancelAnalysis() })
            } else if model.selecting {
                HStack {
                    Text("\(model.picked.count) picked").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    Spacer()
                    Chip(title: "Top 5", selected: false) {
                        model.picked = Set(model.visibleMoments.prefix(5).map(\.id))
                    }
                    Chip(title: "Export \(model.picked.count)", icon: "square.and.arrow.down", selected: !model.picked.isEmpty) {
                        model.exportPicked()
                    }
                    .disabled(model.picked.isEmpty)
                }
            } else {
                HStack(spacing: 8) {
                    Chip(title: "Deep scan", icon: "text.magnifyingglass", selected: false) { model.deepScan() }
                    Chip(title: model.hasAPIKey ? "Claude picks" : "Add Claude", icon: "sparkles", selected: false) {
                        if model.hasAPIKey {
                            Task { await model.aiFind(); model.analysisJob = nil }
                        } else {
                            onSettings()
                        }
                    }
                    Spacer()
                    if let m = model.selectedMoment, !m.postText.isEmpty || !m.postTitle.isEmpty {
                        Button { model.copyPostText(m) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                    }
                }
            }

            let list = model.visibleMoments
            if list.isEmpty {
                Text(model.analysisJob != nil ? "Listening to the stream… cards appear as they're ready."
                                              : "No moments yet.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { n, m in
                            MomentCard(rank: n + 1, m: m,
                                       selected: m.id == model.selectedID && !model.selecting,
                                       picked: model.selecting ? model.picked.contains(m.id) : nil) { model.select(m) }
                        }
                    }
                }
            }
        }
    }
}

struct MomentCard: View {
    let rank: Int
    let m: Moment
    let selected: Bool
    let picked: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%02d", rank))
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(selected ? Theme.accent : .white)
                    Spacer()
                    if let picked {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18)).foregroundStyle(picked ? Theme.accent : Theme.faint)
                    } else {
                        stageIcon
                    }
                }
                Text(m.title.isEmpty ? "Loud moment" : m.title)
                    .font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(m.reason.isEmpty ? (m.transcript.isEmpty ? " " : m.transcript) : m.reason)
                    .font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(clock(m.start)).font(Theme.mono(10.5))
                    Text("·").foregroundStyle(Theme.faint)
                    Text("\(Int(m.duration))s").font(Theme.mono(10.5))
                    Spacer()
                    if m.exported { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
                }
                .foregroundStyle(Theme.dim)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule().fill(m.combined > 0.7 ? Theme.hot : Theme.accent)
                            .frame(width: max(3, g.size.width * CGFloat(m.combined)))
                    }
                }
                .frame(height: 3)
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(width: 168, height: 128, alignment: .topLeading)
            .background(selected ? Theme.raised : Theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var stageIcon: some View {
        switch m.stage {
        case .loud: Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.faint)
        case .listening: PulseDot()
        case .shaped: Image(systemName: "text.quote").foregroundStyle(Theme.dim)
        case .ai: Image(systemName: "sparkles").foregroundStyle(Theme.accent)
        }
    }
}

// MARK: Layout

struct LayoutPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Segments(items: ReelLayout.allCases, label: { $0.rawValue }, value: Binding(
                    get: { model.style.layout },
                    set: { v in
                        if v == .stream && model.style.facecam == nil { model.openFacecamEditor() }
                        model.style.layout = v; model.styleChanged()
                    }))

                switch model.style.layout {
                case .stream:
                    if let job = model.facecamJob { JobRow(job: job) }
                    HStack(spacing: 8) {
                        Chip(title: model.style.facecam == nil ? "Set facecam" : "Adjust facecam", icon: "person.crop.square", selected: false) {
                            model.openFacecamEditor()
                        }
                        Chip(title: "Auto-detect", icon: "viewfinder", selected: false) { model.detectFacecam() }
                    }
                    slider("Facecam size", value: model.bind(\.camShare), range: 0.28...0.5)
                    slider("Gameplay position", value: model.bind(\.panX), range: 0...1)
                case .fit:
                    SectionLabel(text: "Background")
                    Segments(items: ReelBackground.allCases, label: { $0.rawValue }, value: model.bind(\.background))
                case .fill:
                    slider("Crop position", value: model.bind(\.panX), range: 0...1)
                }

                Toggle("Cut silences", isOn: Binding(
                    get: { model.removeSilence },
                    set: { model.removeSilence = $0; model.scheduleRebuild() }))
                    .font(.system(size: 14, weight: .semibold)).tint(Theme.accent)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: title)
            Slider(value: value, in: range).tint(Theme.accent)
        }
    }
}

// MARK: Captions

struct CaptionsPanel: View {
    @Bindable var model: EditorModel
    @State private var editing: PhraseList?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Captions", isOn: model.bind(\.captionsOn))
                    .font(.system(size: 14, weight: .semibold)).tint(Theme.accent)
                if let job = model.captionJob { JobRow(job: job) }

                if model.style.captionsOn {
                    Segments(items: CaptionScript.allCases, label: { $0.rawValue }, value: Binding(
                        get: { model.style.script },
                        set: { model.style.script = $0; model.state.style = model.style; model.captionsChanged() }))

                    Segments(items: CaptionStyleKind.allCases, label: { $0.rawValue }, value: Binding(
                        get: { model.style.captionStyle },
                        set: { model.style.captionStyle = $0; model.state.style = model.style; model.captionsChanged() }))

                    HStack(spacing: 10) {
                        SectionLabel(text: "Spoken word")
                        Spacer()
                        ForEach(0..<CaptionRenderer.palette.count, id: \.self) { i in
                            Circle()
                                .fill(Color(CaptionRenderer.palette[i]))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white, lineWidth: model.style.accent == i ? 2.5 : 0))
                                .onTapGesture { model.style.accent = i; model.styleChanged() }
                        }
                    }

                    HStack(spacing: 8) {
                        Chip(title: model.captionsReady ? "Re-transcribe" : "Transcribe clip", icon: "waveform", selected: !model.captionsReady) {
                            model.generateCaptions()
                        }
                        Chip(title: "Edit text", icon: "pencil", selected: false) {
                            let p = model.captionPhrases()
                            if p.isEmpty { model.show("Transcribe the clip first") } else { editing = PhraseList(items: p) }
                        }
                        Chip(title: "AI fix", icon: "sparkles", selected: false) { model.aiFixCaptions() }
                    }

                    HStack {
                        Menu {
                            ForEach(languages) { l in Button(l.name) { model.setLanguage(l.code) } }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Spoken: " + model.languageName).font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                            }
                            .foregroundStyle(.white)
                        }
                        Spacer()
                        Toggle("Accurate", isOn: Binding(get: { model.accurateModel },
                                                          set: { model.accurateModel = $0; model.captionsChanged() }))
                            .fixedSize().font(.system(size: 13)).tint(Theme.accent)
                    }
                }
            }
        }
        .sheet(item: $editing) { list in
            CaptionEditor(phrases: list.items) { model.applyCaptionEdits($0) }
        }
    }
}

struct PhraseList: Identifiable {
    let id = UUID()
    var items: [EditablePhrase]
}

struct CaptionEditor: View {
    @State var phrases: [EditablePhrase]
    let onSave: ([EditablePhrase]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($phrases) { $p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clock(p.start)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                            TextField("", text: $p.text, axis: .vertical)
                                .font(.system(size: 16, weight: .semibold))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .listRowBackground(Theme.surface)
                    }
                } footer: {
                    Text("Fix any word. Edited lines keep their timing and are shown exactly as you type them.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Caption text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(phrases); dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: Brand (watermark)

struct BrandPanel: View {
    @Bindable var model: EditorModel
    @State private var logoItem: PhotosPickerItem?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Watermark", isOn: model.bind(\.watermarkOn))
                    .font(.system(size: 14, weight: .semibold)).tint(Theme.accent)
                if model.style.watermarkOn {
                    HStack(spacing: 8) {
                        TextField("@yourhandle", text: model.bind(\.watermarkText))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            Group {
                                if let logo = model.logo {
                                    Image(uiImage: logo).resizable().scaledToFit().padding(4)
                                } else {
                                    Image(systemName: "photo.badge.plus").font(.system(size: 15))
                                }
                            }
                            .frame(width: 36, height: 36)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .foregroundStyle(.white)
                        if model.logo != nil {
                            Button { model.setLogo(nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    Segments(items: WatermarkLook.allCases, label: { $0.rawValue }, value: model.bind(\.watermarkLook))
                    HStack(spacing: 6) {
                        SectionLabel(text: "Position")
                        Spacer()
                        ForEach(WatermarkPosition.allCases) { p in
                            Chip(title: p.rawValue, selected: model.style.watermarkPos == p) {
                                model.style.watermarkPos = p; model.styleChanged()
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel(text: "Size")
                            Slider(value: model.bind(\.watermarkSize), in: 0.6...1.8).tint(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel(text: "Opacity")
                            Slider(value: model.bind(\.watermarkOpacity), in: 0.3...1).tint(Theme.accent)
                        }
                    }
                }
            }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    model.setLogo(img.resizedForLogo())
                }
                logoItem = nil
            }
        }
    }
}

extension UIImage {
    func resizedForLogo(max side: CGFloat = 300) -> UIImage {
        let s = min(1, side / max(size.width, size.height))
        guard s < 1 else { return self }
        let target = CGSize(width: size.width * s, height: size.height * s)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

// MARK: FX

struct FXPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                fx("Peak slam", "Flash + giant word on the loudest shout", \.slam)
                fx("Punch-in", "Zooms in when the streamer gets loud", \.punch)
                fx("Retention bar", "Thin progress line along the top", \.progressBar)
                fx("Hype meter", "Bar that follows the streamer's energy", \.hype)
                fx("Hook stays on", "Keep the hook box on screen for the whole short", \.hookStays)
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Hook")
                    HStack(spacing: 8) {
                        TextField("e.g. Ye banda pagal hai 😭", text: model.bind(\.hook))
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        if let m = model.selectedMoment, !m.hook.isEmpty, m.hook != model.style.hook {
                            Chip(title: "AI", icon: "sparkles", selected: false) {
                                model.style.hook = m.hook; model.styleChanged()
                            }
                        }
                    }
                }
            }
        }
    }

    private func fx(_ title: String, _ sub: String, _ kp: WritableKeyPath<ReelStyle, Bool>) -> some View {
        Toggle(isOn: model.bind(kp)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
        }
        .tint(Theme.accent)
    }
}

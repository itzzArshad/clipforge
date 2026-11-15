import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

struct ContentView: View {
    @State private var model = EditorModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var showLink = false
    @State private var tab: EditorTab = .moments

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if model.hasVideo {
                EditorScreen(model: model, tab: $tab,
                             onPhotos: { showPhotos = true },
                             onFiles: { showFiles = true },
                             onLink: { showLink = true },
                             onSettings: { showSettings = true })
            } else {
                WelcomeScreen(busy: model.importJob, onPhotos: { showPhotos = true }, onFiles: { showFiles = true },
                              onLink: { showLink = true })
            }

            VStack {
                if let t = model.toast {
                    Text(t)
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 54)
            .allowsHitTesting(false)
        }
        .animation(.snappy, value: model.toast)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .photosPicker(isPresented: $showPhotos, selection: $pickerItem, matching: .videos)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                model.importJob = Job(title: "Importing video")
                if let f = try? await item.loadTransferable(type: VideoFile.self) {
                    await model.importVideo(f.url)
                } else {
                    model.importJob = nil
                    model.show("Could not import that video")
                }
                pickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                model.importJob = Job(title: "Copying video")
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                do {
                    try await Task.detached { try FileManager.default.copyItem(at: url, to: dest) }.value
                } catch {
                    model.importJob = nil
                    model.show("Copy failed: \(error.localizedDescription)")
                    return
                }
                await model.importVideo(dest)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showLink) {
            LinkSheet(onStart: { link, options in model.importLink(link, options: options) },
                      onSettings: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettings = true } })
        }
        .sheet(item: Binding(get: { model.facecamFrame.map { FrameBox(image: $0) } },
                             set: { if $0 == nil { model.facecamFrame = nil } })) { box in
            FacecamEditor(image: box.image,
                          rect: model.style.facecam ?? CGRect(x: 0.68, y: 0.05, width: 0.28, height: 0.3)) { r in
                model.setFacecam(r)
            }
        }
    }
}

struct FrameBox: Identifiable {
    let image: UIImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}

// MARK: Welcome

struct WelcomeScreen: View {
    let busy: Job?
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: 10, height: 26)
                Text("CLIPFORGE").font(.system(size: 13, weight: .heavy)).tracking(3)
            }
            Text("Streams in.\nShorts out.")
                .font(.system(size: 46, weight: .black))
                .lineSpacing(-4)
                .padding(.top, 18)
            Text("Finds the moments worth posting, cuts each one with its setup and payoff, puts the facecam on top, captions it in Hinglish and stamps your handle.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.dim)
                .padding(.top, 14)

            Spacer()

            if let busy {
                JobRow(job: busy).padding(14).panel()
            } else {
                VStack(spacing: 10) {
                    Button(action: onPhotos) {
                        HStack {
                            Text("Choose a stream").font(.system(size: 17, weight: .bold))
                            Spacer()
                            Image(systemName: "arrow.right").font(.system(size: 16, weight: .bold))
                        }
                        .padding(.horizontal, 20).frame(height: 58)
                        .foregroundStyle(.black)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    Button(action: onLink) {
                        HStack {
                            Text("Paste a Twitch / Kick link").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "link").font(.system(size: 15))
                        }
                        .padding(.horizontal, 20).frame(height: 54)
                        .panel(16)
                    }
                    Button(action: onFiles) {
                        HStack {
                            Text("From Files").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "folder").font(.system(size: 15))
                        }
                        .padding(.horizontal, 20).frame(height: 54)
                        .panel(16)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

// MARK: Editor

struct EditorScreen: View {
    @Bindable var model: EditorModel
    @Binding var tab: EditorTab
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onLink: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            topBar
            PreviewCard(model: model)
            TimelineSection(model: model)
            ToolPanel(model: model, tab: $tab, onSettings: onSettings)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("From Photos", systemImage: "photo.on.rectangle", action: onPhotos)
                Button("From Files", systemImage: "folder", action: onFiles)
                Button("From a link", systemImage: "link", action: onLink)
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40).panel(12)
            }
            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40).panel(12)
            }
            .buttonStyle(.plain)

            Spacer()

            if let job = model.importJob {
                ExportProgress(job: job) { }
            } else if let job = model.exportJob {
                ExportProgress(job: job) { model.cancelExport() }
            } else {
                Button { model.exportCurrent() } label: {
                    HStack(spacing: 6) {
                        Text("Export").font(.system(size: 15, weight: .bold))
                        Image(systemName: "arrow.down").font(.system(size: 13, weight: .heavy))
                    }
                    .padding(.horizontal, 16).frame(height: 40)
                    .foregroundStyle(.black)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
    }
}

struct ExportProgress: View {
    let job: Job
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.raised, lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(job.progress ?? 0)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(job.title).font(.system(size: 12, weight: .semibold))
                Text((job.detail.isEmpty ? "" : job.detail + " · ") + "\(Int((job.progress ?? 0) * 100))%")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
            }
            Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .panel(12)
    }
}

struct PreviewCard: View {
    @Bindable var model: EditorModel

    var body: some View {
        PlayerView(player: model.player)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .overlay(alignment: .bottom) { playbackBar }
            .overlay(alignment: .topLeading) { activity }
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playbackBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 11))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: g.size.width * min(model.playhead / max(model.clipDuration, 0.1), 1))
                }
            }
            .frame(height: 3)
            Text(clock(model.playhead)).font(Theme.mono(10.5, .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 30)
        .glass(15)
        .padding(8)
        .allowsHitTesting(false)
    }

    /// Small live badge when something is running in the background.
    @ViewBuilder private var activity: some View {
        let job = model.analysisJob ?? model.captionJob ?? model.facecamJob
        if let job {
            HStack(spacing: 6) {
                PulseDot()
                Text(job.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                if let p = job.progress { Text("\(Int(p * 100))%").font(Theme.mono(10.5, .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .glass(13)
            .padding(8)
            .allowsHitTesting(false)
        }
    }
}

struct ToolPanel: View {
    @Bindable var model: EditorModel
    @Binding var tab: EditorTab
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .moments: MomentsPanel(model: model, onSettings: onSettings)
                case .layout: LayoutPanel(model: model)
                case .captions: CaptionsPanel(model: model)
                case .brand: BrandPanel(model: model)
                case .fx: FXPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .frame(height: 196)

            Rectangle().fill(Theme.line).frame(height: 1)

            HStack(spacing: 0) {
                ForEach(EditorTab.allCases) { t in
                    Button { withAnimation(.snappy(duration: 0.2)) { tab = t } } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 15, weight: .semibold))
                            Text(t.title.uppercased()).font(.system(size: 8.5, weight: .bold)).tracking(0.8)
                            Rectangle().fill(tab == t ? Theme.accent : .clear).frame(width: 16, height: 2)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 4)
                        .foregroundStyle(tab == t ? Color.white : Theme.faint)
                        .overlay(alignment: .topTrailing) { badge(for: t) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .panel(18)
    }

    @ViewBuilder private func badge(for t: EditorTab) -> some View {
        let busy = (t == .moments && model.analysisJob != nil) || (t == .captions && model.captionJob != nil)
            || (t == .layout && model.facecamJob != nil)
        if busy {
            Circle().fill(Theme.accent).frame(width: 6, height: 6).padding(.top, 6).padding(.trailing, 18)
        }
    }
}

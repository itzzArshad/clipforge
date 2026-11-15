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
    @State private var tab: EditorTab = .moments

    var body: some View {
        ZStack {
            AmbientBackground()

            if model.hasVideo {
                EditorScreen(model: model, tab: $tab,
                             onPhotos: { showPhotos = true },
                             onFiles: { showFiles = true },
                             onSettings: { showSettings = true })
            } else {
                WelcomeScreen(onPhotos: { showPhotos = true }, onFiles: { showFiles = true })
            }

            if let text = model.busyText {
                BusyOverlay(text: text, progress: model.progress,
                            onCancel: model.analyzing ? { model.cancelAnalysis() } : nil)
                    .transition(.opacity)
            }

            VStack {
                if let t = model.toast {
                    Text(t)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(22)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 6)
            .allowsHitTesting(false)
        }
        .animation(.snappy, value: model.toast)
        .animation(.snappy, value: model.busyText)
        .preferredColorScheme(.dark)
        .photosPicker(isPresented: $showPhotos, selection: $pickerItem, matching: .videos)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                model.busyText = "Importing video…"
                if let f = try? await item.loadTransferable(type: VideoFile.self) {
                    await model.importVideo(f.url)
                } else {
                    model.busyText = nil
                    model.show("Could not import that video")
                }
                pickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                model.busyText = "Copying video…"
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                do {
                    try await Task.detached { try FileManager.default.copyItem(at: url, to: dest) }.value
                } catch {
                    model.busyText = nil
                    model.show("Copy failed: \(error.localizedDescription)")
                    return
                }
                await model.importVideo(dest)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }
}

// MARK: Welcome

struct WelcomeScreen: View {
    let onPhotos: () -> Void
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "scissors.badge.ellipsis")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("ClipForge").font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("Turn long streams into reels.\nFinds the wild moments, captions them, makes them pop.")
                    .font(.system(size: 15)).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
            VStack(spacing: 12) {
                Button(action: onPhotos) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .glass(27, tint: Theme.accent, interactive: true)
                }
                Button(action: onFiles) {
                    Label("Choose from Files", systemImage: "folder")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .glass(27, interactive: true)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            Spacer()
        }
    }
}

// MARK: Editor

struct EditorScreen: View {
    @Bindable var model: EditorModel
    @Binding var tab: EditorTab
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
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
            } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).glass(22, interactive: true)
            }
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44).glass(22, interactive: true)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { Task { await model.export() } } label: {
                Label("Export", systemImage: "arrow.up.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 44)
                    .glass(22, tint: Theme.accent, interactive: true)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }
}

struct PreviewCard: View {
    @Bindable var model: EditorModel

    var body: some View {
        PlayerView(player: model.player)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .overlay(alignment: .bottom) { playbackBar }
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13))
            ProgressView(value: min(model.playhead / max(model.clipDuration, 0.1), 1)).tint(.white)
            Text("\(clock(model.playhead)) / \(clock(model.clipDuration))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(20)
        .padding(10)
        .allowsHitTesting(false)
    }
}

struct ToolPanel: View {
    @Bindable var model: EditorModel
    @Binding var tab: EditorTab
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(EditorTab.allCases) { t in
                    Button { withAnimation(.snappy) { tab = t } } label: {
                        VStack(spacing: 2) {
                            Image(systemName: t.icon).font(.system(size: 16, weight: .semibold))
                            Text(t.title).font(.system(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(tab == t ? Color.white : Color.white.opacity(0.55))
                        .background { if tab == t { Capsule().fill(Color.white.opacity(0.16)) } }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glass(26)

            Group {
                switch tab {
                case .moments: MomentsPanel(model: model, onSettings: onSettings)
                case .layout: LayoutPanel(model: model)
                case .captions: CaptionsPanel(model: model)
                case .effects: EffectsPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .frame(height: 190)
            .glass(26)
        }
    }
}

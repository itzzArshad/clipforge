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
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var videoURL: URL?
    @State private var duration: Double = 0
    @State private var bins: [Float] = []
    @State private var highlights: [Highlight] = []
    @State private var start: Double = 0
    @State private var end: Double = 30
    @State private var removeSilence = true
    @State private var panX: Double = 0.5
    @State private var status = "Pick a video to begin"
    @State private var busy = false
    @State private var player = AVPlayer()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("Pick from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { showFiles = true } label: {
                        Label("Pick from Files", systemImage: "folder")
                    }
                }

                if videoURL != nil {
                    Section("Preview") {
                        VideoPlayer(player: player).frame(height: 260)
                    }
                    Section("Candidates (loudest moments)") {
                        ForEach(highlights) { h in
                            Button { select(h) } label: {
                                HStack {
                                    Text("\(fmt(h.start)) – \(fmt(h.end))")
                                    Spacer()
                                    Text(String(format: "%.0f", h.score)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Trim  (\(fmt(start)) – \(fmt(end)))") {
                        Slider(value: $start, in: 0...max(duration - 1, 1))
                            .onChange(of: start) { _, v in
                                if end < v + 1 { end = min(v + 1, duration) }
                                seek(v)
                            }
                        Slider(value: $end, in: (start + 1)...max(duration, start + 2))
                    }
                    Section("Options") {
                        Toggle("Remove silences", isOn: $removeSilence)
                        VStack(alignment: .leading) {
                            Text("Crop position (left → right)").font(.footnote)
                            Slider(value: $panX, in: 0...1)
                        }
                    }
                    Section {
                        Button { Task { await export() } } label: {
                            Text("Export 1080×1920 to Photos").bold()
                        }.disabled(busy)
                    }
                }

                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("ClipForge")
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    status = "Importing…"
                    if let f = try? await item.loadTransferable(type: VideoFile.self) {
                        await load(f.url)
                    } else {
                        status = "Could not import that video"
                    }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                do { try FileManager.default.copyItem(at: url, to: dest) }
                catch { status = "Copy failed: \(error.localizedDescription)"; return }
                Task { await load(dest) }
            }
        }
    }

    func load(_ url: URL) async {
        busy = true
        status = "Analyzing audio…"
        do {
            let asset = AVURLAsset(url: url)
            duration = try await asset.load(.duration).seconds
            videoURL = url
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            bins = try await AudioAnalyzer.loudness(url: url)
            highlights = AudioAnalyzer.highlights(bins: bins)
            if let first = highlights.first {
                select(first)
            } else {
                start = 0
                end = min(60, duration)
            }
            status = "Found \(highlights.count) candidate moments"
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
        busy = false
    }

    func select(_ h: Highlight) {
        start = h.start
        end = min(h.end, duration)
        seek(start)
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func export() async {
        guard let url = videoURL else { return }
        busy = true
        status = "Exporting…"
        do {
            let keep = removeSilence
                ? AudioAnalyzer.keepRanges(bins: bins, start: start, end: end)
                : [start...end]
            let out = try await Exporter.export(url: url, keep: keep, panX: panX)
            try await Exporter.saveToPhotos(out)
            status = "Saved to Photos ✓"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
        busy = false
    }

    func fmt(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

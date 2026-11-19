import AVFoundation
import CoreMedia

/// Turns MPEG-TS stream segments (what Twitch and Kick serve) into one MP4 the editor can read, on the phone.
/// AVFoundation cannot open .ts files, so this reads the transport stream itself (PAT/PMT/PES), pulls out the
/// H.264 frames and AAC frames with their timestamps, and writes them unchanged (no re-encode) with AVAssetWriter.
final class TSRemuxer {
    enum RemuxError: LocalizedError {
        case unsupported(String), writer(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let s): return s
            case .writer(let s): return "Could not write the video: \(s)"
            }
        }
    }

    private let output: URL
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?

    // demux state
    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var pes: [Int: Data] = [:]
    private var leftover = Data()

    // formats + timing
    private var sps: Data?
    private var pps: Data?
    private var vFormat: CMVideoFormatDescription?
    private var aFormat: CMAudioFormatDescription?
    private var aSampleRate: Double = 48000
    private var basePTS: Int64?
    private var lastRaw: [Int: Int64] = [:]
    private var unwrapped: [Int: Int64] = [:]
    private var sawKeyframe = false
    private var pending: [CMSampleBuffer] = []     // samples seen before both formats were known
    private(set) var writtenSeconds: Double = 0

    init(output: URL) {
        self.output = output
        try? FileManager.default.removeItem(at: output)
    }

    // MARK: feeding

    /// Feed one whole segment (or any chunk of TS bytes).
    func append(_ chunk: Data) throws {
        var data = leftover
        data.append(chunk)
        leftover = Data()
        var i = data.startIndex
        // resync on the 0x47 sync byte
        while i < data.endIndex && data[i] != 0x47 { i += 1 }
        while i + 188 <= data.endIndex {
            if data[i] != 0x47 {
                i += 1
                while i < data.endIndex && data[i] != 0x47 { i += 1 }
                continue
            }
            try packet(data[i..<(i + 188)])
            i += 188
        }
        if i < data.endIndex { leftover = Data(data[i..<data.endIndex]) }
    }

    /// Call after the last segment. Writes out what is buffered and closes the file.
    func finish() async throws -> URL {
        for pid in Array(pes.keys) { try flushPES(pid) }
        if writer == nil, vFormat != nil, !pending.isEmpty {
            try startWriter()
            for b in pending {
                let isVideo = CMSampleBufferGetFormatDescription(b).map { CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video } ?? false
                if isVideo { vQueue.append(b) } else { aQueue.append(b) }
            }
            pending = []
        }
        guard let writer else { throw RemuxError.unsupported("The stream had no H.264 video that the phone can read.") }
        try drain(force: true)
        finishVideo()
        finishAudio()
        await writer.finishWriting()
        if writer.status != .completed {
            throw RemuxError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        return output
    }

    func cancel() {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: output)
    }

    // MARK: transport stream

    private func packet(_ p: Data) throws {
        let b = [UInt8](p)
        let pusi = (b[1] & 0x40) != 0
        let pid = (Int(b[1] & 0x1F) << 8) | Int(b[2])
        let afc = (b[3] >> 4) & 0x3
        var off = 4
        if afc == 2 || afc == 3 { off += 1 + Int(b[4]) }
        guard afc == 1 || afc == 3, off < 188 else { return }
        let payload = Data(b[off..<188])

        if pid == 0 {
            parsePAT(payload, pusi: pusi)
        } else if pid == pmtPID {
            parsePMT(payload, pusi: pusi)
        } else if pid == videoPID || pid == audioPID {
            if pusi { try flushPES(pid); pes[pid] = Data() }
            pes[pid]?.append(payload)
        }
    }

    private func section(_ payload: Data, pusi: Bool) -> [UInt8]? {
        let b = [UInt8](payload)
        guard pusi, !b.isEmpty else { return nil }
        let start = 1 + Int(b[0])
        guard start + 3 <= b.count else { return nil }
        let len = (Int(b[start + 1] & 0x0F) << 8) | Int(b[start + 2])
        guard start + 3 + len <= b.count else { return nil }
        return Array(b[start..<(start + 3 + len)])
    }

    private func parsePAT(_ payload: Data, pusi: Bool) {
        guard let s = section(payload, pusi: pusi), s.count >= 12 else { return }
        var i = 8
        while i + 4 <= s.count - 4 {
            let program = (Int(s[i]) << 8) | Int(s[i + 1])
            let pid = (Int(s[i + 2] & 0x1F) << 8) | Int(s[i + 3])
            if program != 0 { pmtPID = pid; break }
            i += 4
        }
    }

    private func parsePMT(_ payload: Data, pusi: Bool) {
        guard let s = section(payload, pusi: pusi), s.count >= 16 else { return }
        let infoLen = (Int(s[10] & 0x0F) << 8) | Int(s[11])
        var i = 12 + infoLen
        while i + 5 <= s.count - 4 {
            let type = s[i]
            let pid = (Int(s[i + 1] & 0x1F) << 8) | Int(s[i + 2])
            let esLen = (Int(s[i + 3] & 0x0F) << 8) | Int(s[i + 4])
            if type == 0x1B && videoPID == nil { videoPID = pid }           // H.264
            if type == 0x0F && audioPID == nil { audioPID = pid }           // AAC (ADTS)
            i += 5 + esLen
        }
    }

    private func flushPES(_ pid: Int) throws {
        guard let d = pes[pid], d.count > 9 else { pes[pid] = nil; return }
        pes[pid] = nil
        let b = [UInt8](d)
        guard b[0] == 0, b[1] == 0, b[2] == 1 else { return }
        let flags = b[7]
        let hlen = Int(b[8])
        guard 9 + hlen <= b.count else { return }
        var pts: Int64?, dts: Int64?
        if flags & 0x80 != 0 { pts = timestamp(b, 9) }
        if flags & 0x40 != 0 { dts = timestamp(b, 14) }
        guard let rawPTS = pts else { return }
        let body = Data(b[(9 + hlen)...])
        let p = unwrap(pid, rawPTS)
        let dt = dts.map { unwrap(pid + 10_000, $0) } ?? p
        if pid == videoPID { try video(body, pts: p, dts: dt) } else { try audio(body, pts: p) }
    }

    private func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        guard i + 5 <= b.count else { return 0 }
        let a = Int64(b[i] & 0x0E) << 29
        let c = Int64(b[i + 1]) << 22 | Int64(b[i + 2] & 0xFE) << 14
        let d = Int64(b[i + 3]) << 7 | Int64(b[i + 4] >> 1)
        return a | c | d
    }

    /// 33-bit 90 kHz clock that wraps every ~26 hours; keep it increasing.
    private func unwrap(_ key: Int, _ raw: Int64) -> Int64 {
        let wrap: Int64 = 1 << 33
        guard let last = lastRaw[key], let u = unwrapped[key] else {
            lastRaw[key] = raw; unwrapped[key] = raw; return raw
        }
        var delta = raw - last
        if delta < -wrap / 2 { delta += wrap }
        if delta > wrap / 2 { delta -= wrap }
        lastRaw[key] = raw
        unwrapped[key] = u + delta
        return u + delta
    }

    private func cm(_ t: Int64) -> CMTime {
        CMTime(value: t - (basePTS ?? t), timescale: 90000)
    }

    // MARK: H.264

    private func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(Int, Int)] = []      // (start of NAL, length of start code)
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i + 3, 3)); i += 3; continue }
                if i + 4 <= b.count && b[i + 2] == 0 && b[i + 3] == 1 { starts.append((i + 4, 4)); i += 4; continue }
            }
            i += 1
        }
        var out: [Data] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].0 - starts[n + 1].1 : b.count
            if end > s.0 { out.append(Data(b[s.0..<end])) }
        }
        return out
    }

    private func video(_ body: Data, pts: Int64, dts: Int64) throws {
        var frame = Data()
        var key = false
        for nal in nalUnits(body) {
            let type = nal[nal.startIndex] & 0x1F
            switch type {
            case 7: if sps == nil { sps = nal }
            case 8: if pps == nil { pps = nal }
            case 9: continue                     // access unit delimiter
            case 5: key = true
            default: break
            }
            var len = UInt32(nal.count).bigEndian
            frame.append(Data(bytes: &len, count: 4))
            frame.append(nal)
        }
        if vFormat == nil, let sps, let pps {
            vFormat = try makeVideoFormat(sps: sps, pps: pps)
        }
        guard let vFormat, !frame.isEmpty else { return }
        if !sawKeyframe { guard key else { return }; sawKeyframe = true }
        if basePTS == nil { basePTS = min(dts, pts) }

        let buf = try sampleBuffer(frame, format: vFormat, pts: cm(pts), dts: cm(dts))
        if !key, let att = CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        writtenSeconds = max(writtenSeconds, cm(pts).seconds)
        try write(buf, video: true)
    }

    private func makeVideoFormat(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p -> OSStatus in
                let ptrs: [UnsafePointer<UInt8>] = [s.bindMemory(to: UInt8.self).baseAddress!,
                                                    p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else { throw RemuxError.unsupported("Unreadable video settings in the stream (\(status)).") }
        return fmt
    }

    private func sampleBuffer(_ data: Data, format: CMFormatDescription, pts: CMTime, dts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw RemuxError.writer("memory (\(status))") }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw RemuxError.writer("copy (\(status))") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var size = data.count
        var out: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &out)
        guard status == noErr, let out else { throw RemuxError.writer("sample (\(status))") }
        return out
    }

    // MARK: AAC

    private static let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private func audio(_ body: Data, pts: Int64) throws {
        let b = [UInt8](body)
        var i = 0, n = 0
        while i + 7 <= b.count {
            guard b[i] == 0xFF, (b[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }
            let protectionAbsent = (b[i + 1] & 0x01) == 1
            let profile = Int((b[i + 2] >> 6) & 0x3)          // object type - 1
            let srIndex = Int((b[i + 2] >> 2) & 0xF)
            let channels = Int((b[i + 2] & 0x1) << 2 | (b[i + 3] >> 6))
            let frameLen = Int(b[i + 3] & 0x3) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            let header = protectionAbsent ? 7 : 9
            guard frameLen > header, i + frameLen <= b.count, srIndex < Self.rates.count else { break }
            if aFormat == nil {
                aSampleRate = Self.rates[srIndex]
                aFormat = try makeAudioFormat(objectType: profile + 1, srIndex: srIndex, channels: max(1, channels))
            }
            if let aFormat, sawKeyframe, basePTS != nil {
                let frame = Data(b[(i + header)..<(i + frameLen)])
                let offset = Int64(Double(n * 1024) / aSampleRate * 90000)
                let buf = try audioBuffer(frame, format: aFormat, pts: cm(pts + offset))
                try write(buf, video: false)
            }
            n += 1
            i += frameLen
        }
    }

    private func makeAudioFormat(objectType: Int, srIndex: Int, channels: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.rates[srIndex], mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(objectType),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        // AudioSpecificConfig: object type (5 bits), rate index (4), channels (4), 3 zero bits
        let asc: [UInt8] = [UInt8((objectType << 3) | (srIndex >> 1)), UInt8(((srIndex & 1) << 7) | (channels << 3))]
        var fmt: CMAudioFormatDescription?
        let status = asc.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: asc.count, magicCookie: $0.baseAddress,
                                           extensions: nil, formatDescriptionOut: &fmt)
        }
        guard status == noErr, let fmt else { throw RemuxError.unsupported("Unreadable audio settings in the stream (\(status)).") }
        return fmt
    }

    private func audioBuffer(_ data: Data, format: CMAudioFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw RemuxError.writer("memory (\(status))") }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw RemuxError.writer("copy (\(status))") }
        var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        var out: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: pts, packetDescriptions: &desc, sampleBufferOut: &out)
        guard status == noErr, let out else { throw RemuxError.writer("audio sample (\(status))") }
        return out
    }

    // MARK: writing

    // Separate queues for video and audio: AVAssetWriter interleaves the two tracks and can refuse one track until
    // the other catches up, so a frame is never waited on while the other track's frames are still to come.
    private var vQueue: [CMSampleBuffer] = []
    private var aQueue: [CMSampleBuffer] = []
    private var vDone = false, aDone = false

    private func finishVideo() { if !vDone { vDone = true; vInput?.markAsFinished() } }
    private func finishAudio() { if !aDone { aDone = true; aInput?.markAsFinished() } }

    private func write(_ buf: CMSampleBuffer, video: Bool) throws {
        if writer == nil {
            pending.append(buf)
            let audioKnown = audioPID == nil || aFormat != nil
            guard vFormat != nil, audioKnown || pending.count > 300 else { return }
            try startWriter()
            for b in pending {
                let isVideo = CMSampleBufferGetFormatDescription(b).map { CMFormatDescriptionGetMediaType($0) == kCMMediaType_Video } ?? false
                if isVideo { vQueue.append(b) } else { aQueue.append(b) }
            }
            pending = []
            try drain(force: false)
            return
        }
        if video { vQueue.append(buf) } else { aQueue.append(buf) }
        try drain(force: false)
    }

    private func drain(force: Bool) throws {
        var spins = 0
        if aInput == nil { aQueue.removeAll() }
        while true {
            if writer?.status == .failed {
                throw RemuxError.writer(writer?.error?.localizedDescription ?? "failed")
            }
            var progressed = false
            if let v = vInput, !vQueue.isEmpty, v.isReadyForMoreMediaData {
                let b = vQueue.removeFirst()
                if CMSampleBufferGetPresentationTimeStamp(b).seconds >= 0 { v.append(b) }
                progressed = true
            }
            if let a = aInput, !aQueue.isEmpty, a.isReadyForMoreMediaData {
                let b = aQueue.removeFirst()
                if CMSampleBufferGetPresentationTimeStamp(b).seconds >= 0 { a.append(b) }
                progressed = true
            }
            if progressed { spins = 0; continue }
            let backlog = vQueue.count + aQueue.count
            if backlog == 0 { return }
            if force {
                // nothing more is coming: a track with an empty queue is done, which frees the other one
                if vQueue.isEmpty { finishVideo() }
                if aQueue.isEmpty { finishAudio() }
            } else if backlog < 800 {
                return          // let more of the stream arrive
            }
            usleep(2000)
            spins += 1
            if spins > 15000 { throw RemuxError.writer("the writer stopped accepting frames") }
        }
    }

    private func startWriter() throws {
        let w: AVAssetWriter
        do { w = try AVAssetWriter(outputURL: output, fileType: .mp4) } catch { throw RemuxError.writer(error.localizedDescription) }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
        v.expectsMediaDataInRealTime = false
        guard w.canAdd(v) else { throw RemuxError.writer("video track") }
        w.add(v)
        vInput = v
        if let aFormat {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFormat)
            a.expectsMediaDataInRealTime = false
            if w.canAdd(a) { w.add(a); aInput = a }
        }
        guard w.startWriting() else { throw RemuxError.writer(w.error?.localizedDescription ?? "start") }
        w.startSession(atSourceTime: .zero)
        writer = w
    }
}

private extension Double {
    var nanToZero: Double { isNaN ? 0 : self }
}

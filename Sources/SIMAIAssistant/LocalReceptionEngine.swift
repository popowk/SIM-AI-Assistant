#if os(macOS)
import Foundation
import AVFoundation
import Darwin
import SIMAICore

/// Owns one persistent, completely offline recognizer and pre-rendered,
/// fixed system-voice replies. The phone audio stays in bounded RAM buffers.
/// Only fixed status codes go to diagnostic logs. Transcripts are in-memory UI.
final class LocalReceptionEngine {
    enum Event { case ready, status(String), heard(String), failed(String) }
    private let gate = NSLock()
    private let writeQueue = DispatchQueue(label: "simai.local.asr.write")
    private let prepareQueue = DispatchQueue(label: "simai.local.prepare", qos: .userInitiated)
    private let onEvent: (Event) -> Void
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBytes = Data()
    private var disposed = false
    private var ready = false
    private var active = false
    private var generation = 0
    private var pending = 0
    private var replyPCM: [LocalReceptionPolicy.Reply: [UInt8]] = [:]
    private var speaking: [UInt8] = []
    private var cursor = 0
    private var quietUntil = Date.distantPast
    private var policy = LocalReceptionPolicy()
    private var ignoreAfterGoodbye = false
    private var capture: LocalCallCapture?
    private var consentPending = false
    init(onEvent: @escaping (Event) -> Void) { self.onEvent = onEvent }
    var isReady: Bool { gate.lock(); defer { gate.unlock() }; return ready && !disposed }
    func prepare() {
        prepareQueue.async { [weak self] in self?.load() }
    }
    private func load() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("LocalReception"),
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("simai-local-asr").path) else {
            fail("LOCAL_ASR_NOT_BUNDLED"); return
        }
        onEvent(.status("正在准备系统中文语音及本地识别模型…"))
        var rendered: [LocalReceptionPolicy.Reply: [UInt8]] = [:]
        for phrase in LocalReceptionPolicy.Reply.allCases {
            gate.lock(); let canceled = disposed; gate.unlock()
            if canceled { return }
            guard let bytes = Self.renderFixedPhrase(phrase.text) else {
                fail("LOCAL_CHINESE_VOICE_UNAVAILABLE"); return
            }
            rendered[phrase] = bytes
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = root.appendingPathComponent("simai-local-asr")
        child.arguments = [root.appendingPathComponent("models").path]
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        // Do not let a dead helper send SIGPIPE to the host app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        child.terminationHandler = { [weak self] _ in self?.fail("LOCAL_ASR_EXITED") }
        gate.lock()
        guard !disposed else { gate.unlock(); return }
        replyPCM = rendered; process = child; input = stdin; output = stdout
        gate.unlock()
        do { try child.run() }
        catch { fail("LOCAL_ASR_LAUNCH_FAILED"); return }
        gate.lock(); let canceled = disposed; gate.unlock()
        if canceled { if child.isRunning { child.terminate() }; return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.isReady else { return }
            self.fail("LOCAL_ASR_READY_TIMEOUT")
        }
    }
    private func consume(_ data: Data) {
        gate.lock()
        guard !disposed else { gate.unlock(); return }
        outputBytes.append(data)
        if outputBytes.count > 65536 { outputBytes.removeAll(); gate.unlock(); fail("LOCAL_ASR_PROTOCOL"); return }
        var lines: [String] = []
        while let end = outputBytes.firstIndex(of: 10) {
            if let line = String(data: outputBytes.prefix(upTo: end), encoding: .utf8) {
                lines.append(line)
            }
            outputBytes.removeSubrange(...end)
        }
        gate.unlock()
        for line in lines {
            if line == "SIMAI_READY" {
                gate.lock()
                let notify = !ready && !disposed
                if notify { ready = true }
                gate.unlock()
                if notify { onEvent(.ready) }
            } else if line.hasPrefix("SIMAI_TEXT ") {
                let text = String(line.dropFirst("SIMAI_TEXT ".count).prefix(600))
                gate.lock()
                guard active, !disposed, !ignoreAfterGoodbye,
                      cursor >= speaking.count, Date() >= quietUntil else { gate.unlock(); continue }
                let reply: LocalReceptionPolicy.Reply
                if consentPending {
                    consentPending = false
                    if LocalCaptureConsent.accepts(text) {
                        capture?.authorize()
                        reply = .consentAccepted
                    } else {
                        capture?.revoke()
                        reply = .consentDeclined
                    }
                } else if LocalCaptureConsent.revokes(text) {
                    capture?.revoke()
                    reply = .consentDeclined
                } else {
                    reply = policy.reply(to: text)
                    capture?.addTurn(text, reply: reply)
                }
                speaking = replyPCM[reply] ?? []
                cursor = 0
                if reply == .goodbye { ignoreAfterGoodbye = true }
                gate.unlock()
                onEvent(.heard(text))
                onEvent(.status(reply == .goodbye ? "已礼貌告别，等待对方挂机" : "已识别来意，正在回复"))
            }
        }
    }

    /// Invoked only after the Android PCM handshake. No desktop audio output.
    func beginCall(capture: LocalCallCapture? = nil) -> Bool {
        gate.lock()
        guard ready, !disposed, !active, let greeting = replyPCM[capture?.greeting ?? .greeting], !greeting.isEmpty else { gate.unlock(); return false }
        self.capture = capture
        consentPending = capture != nil
        generation += 1; let epoch = generation
        active = true; policy = LocalReceptionPolicy(); ignoreAfterGoodbye = false
        speaking = greeting; cursor = 0; quietUntil = .distantPast
        gate.unlock()
        enqueueReset(epoch)
        onEvent(.status("本地接待已连接，正在播放接待问候"))
        return true
    }
    func endCall() {
        gate.lock()
        if !active { gate.unlock(); return }
        active = false; generation += 1; let epoch = generation
        capture = nil; consentPending = false
        speaking.removeAll(); cursor = 0
        gate.unlock()
        enqueueReset(epoch)
        onEvent(.status("本地接待已结束"))
    }
    private func enqueueReset(_ epoch: Int) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.gate.lock()
            let handle = (!self.disposed && self.generation == epoch) ? self.input?.fileHandleForWriting : nil
            self.gate.unlock()
            if let handle {
                do { try handle.write(contentsOf: Data([1])) }
                catch { self.fail("LOCAL_ASR_WRITE_FAILED") }
            }
        }
    }
    func feed(_ pcm: [UInt8]) {
        guard pcm.count == 640 else { return }
        gate.lock()
        // First release uses half-duplex; no microphone and no echo path.
        guard active, ready, !disposed, !ignoreAfterGoodbye, cursor >= speaking.count,
              Date() >= quietUntil, pending < 30 else { gate.unlock(); return }
        pending += 1; let epoch = generation
        gate.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.gate.lock()
            let handle = (!self.disposed && self.active && self.generation == epoch &&
                          self.cursor >= self.speaking.count) ? self.input?.fileHandleForWriting : nil
            self.gate.unlock()
            defer { self.gate.lock(); self.pending -= 1; self.gate.unlock() }
            guard let handle else { return }
            do {
                var data = Data([0]); data.append(contentsOf: pcm)
                try handle.write(contentsOf: data)
            } catch { self.fail("LOCAL_ASR_WRITE_FAILED") }
        }
    }
    /// Called by the existing 20ms PSTN uplink pacer.
    func nextFrame() -> [UInt8] {
        gate.lock(); defer { gate.unlock() }
        var bytes = [UInt8](repeating: 0, count: 640)
        guard active, ready, !disposed, cursor < speaking.count else { return bytes }
        let n = min(640, speaking.count - cursor)
        bytes.replaceSubrange(0..<n, with: speaking[cursor..<(cursor+n)])
        cursor += n
        if cursor == speaking.count { quietUntil = Date().addingTimeInterval(0.25) }
        return bytes
    }
    func stop() { dispose(error: nil) }
    private func fail(_ code: String) { dispose(error: code) }
    private func dispose(error: String?) {
        gate.lock()
        guard !disposed else { gate.unlock(); return }
        disposed = true; ready = false; active = false
        speaking.removeAll(); replyPCM.removeAll(); outputBytes.removeAll()
        let child = process; let stdout = output; let stdin = input
        process = nil; input = nil; output = nil
        gate.unlock()
        stdout?.fileHandleForReading.readabilityHandler = nil
        if let child, child.isRunning { child.terminate() }
        writeQueue.async { try? stdin?.fileHandleForWriting.close() }
        if let error { onEvent(.failed(error)) }
    }
    deinit { stop() }

    /// Synthesize only fixed, non-private phrases into temporary AIFF files.
    /// The system voice never receives any caller transcript or raw audio.
    private static func renderFixedPhrase(_ text: String) -> [UInt8]? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("simai-tts-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("reply.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Tingting", "-r", "190", "-o", url.path, text]
        say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
        do { try say.run() } catch { return nil }
        let until = Date().addingTimeInterval(8)
        while say.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        if say.isRunning { say.terminate(); return nil }
        guard say.terminationStatus == 0,
              let file = try? AVAudioFile(forReading: url),
              file.length > 0, file.processingFormat.sampleRate > 0,
              Double(file.length) / file.processingFormat.sampleRate <= 15,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData, buffer.frameLength > 1 else { return nil }
        let frames = Int(buffer.frameLength)
        let n = Int(Double(frames) * 16000 / buffer.format.sampleRate)
        guard n > 320 && n <= 240000 else { return nil }
        var pcm = [UInt8](); pcm.reserveCapacity(n * 2)
        let ratio = buffer.format.sampleRate / 16000
        let count = Int(buffer.format.channelCount)
        guard count > 0 else { return nil }
        func sample(_ i: Int) -> Double {
            var total = 0.0
            for channel in 0..<count {
                total += Double(buffer.format.isInterleaved
                    ? channels[0][i * count + channel] : channels[channel][i])
            }
            return total / Double(count)
        }
        var peak = 0.0
        for i in 0..<n {
            let pos = Double(i) * ratio
            let a = min(frames - 1, Int(pos)), b = min(frames - 1, a + 1)
            let frac = pos - Double(a)
            let value = (sample(a) * (1-frac) + sample(b) * frac) * 0.75
            let safe = value.isFinite ? min(0.95, max(-0.95, value)) : 0
            peak = max(peak, abs(safe))
            let bits = UInt16(bitPattern: Int16(safe * 32767))
            pcm.append(UInt8(truncatingIfNeeded: bits)); pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return peak > 0.003 ? pcm : nil
    }
}
#endif

#if os(macOS)
import Foundation
import AVFoundation
import Darwin
import SIMAICore

/// One preview call is limited to 180 seconds. Raw samples stay in process
/// memory only; neither the audio nor the per-session token is logged or saved.
enum LiveAudioEvent {
    case status(String)
    case active
    case metrics(received: Int, sent: Int, dropped: Int)
    case finished(String)
}

private enum LiveAudioFailure: Error {
    case reason(String)
}

private final class MicrophonePCMQueue {
    private var buffer: [Int16] = []
    private let lock = NSLock()
    func append(_ values: [Int16]) {
        lock.lock()
        buffer.append(contentsOf: values)
        if buffer.count > 9600 { buffer.removeFirst(buffer.count - 9600) }
        lock.unlock()
    }
    func nextFrame() -> [UInt8] {
        lock.lock()
        var values = [Int16](repeating: 0, count: 320)
        if buffer.count >= 320 {
            values = Array(buffer.prefix(320))
            buffer.removeFirst(320)
        }
        lock.unlock()
        var output = [UInt8](repeating: 0, count: 640)
        for i in 0..<320 {
            let bits = UInt16(bitPattern: values[i])
            output[i * 2] = UInt8(truncatingIfNeeded: bits)
            output[i * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
        }
        return output
    }
    func clear() { lock.lock(); buffer.removeAll(keepingCapacity: true); lock.unlock() }
}

private final class LiveMacMicrophone {
    private let queue: MicrophonePCMQueue
    private var engine: AVAudioEngine?
    init(queue: MicrophonePCMQueue) { self.queue = queue }

    func start() throws {
        guard engine == nil else { return }
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw LiveAudioFailure.reason("MIC_FORMAT_UNSUPPORTED") }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self, converter, target] original, _ in
            guard let self else { return }
            let needed = max(512, Int(ceil(Double(original.frameLength) *
                                          16000.0 / format.sampleRate)) + 128)
            guard let reduced = AVAudioPCMBuffer(pcmFormat: target,
                                                 frameCapacity: AVAudioFrameCount(needed)) else { return }
            var supplied = false
            var convertError: NSError?
            _ = converter.convert(to: reduced, error: &convertError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return original
            }
            guard convertError == nil, reduced.frameLength > 0,
                  let samples = reduced.floatChannelData?[0] else { return }
            var pcm: [Int16] = []
            pcm.reserveCapacity(Int(reduced.frameLength))
            for i in 0..<Int(reduced.frameLength) {
                // Limiter prevents unexpected clipped/loud microphone audio.
                let value = max(-0.6, min(0.6, samples[i] * 0.55))
                pcm.append(Int16(value * 32767))
            }
            self.queue.append(pcm)
        }
        do {
            try audio.start()
            engine = audio
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        queue.clear()
    }
}

private final class LiveMacSpeaker {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let gate = NSLock()
    private var pending = 0
    private var dropped = 0

    init() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1,
                                         interleaved: false) else {
            throw LiveAudioFailure.reason("SPEAKER_FORMAT")
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
    }

    func feed(_ bytes: [UInt8]) {
        guard bytes.count == 640,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320),
              let output = pcm.floatChannelData?[0] else { return }
        gate.lock()
        if pending >= 12 {
            dropped += 1
            gate.unlock()
            return
        }
        pending += 1
        gate.unlock()
        pcm.frameLength = 320
        for i in 0..<320 {
            let value = UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8
            output[i] = Float(Int16(bitPattern: value)) / 32768
        }
        player.scheduleBuffer(pcm, completionHandler: { [weak self] in
            guard let self else { return }
            self.gate.lock()
            self.pending = max(0, self.pending - 1)
            self.gate.unlock()
        })
    }
    func droppedFrames() -> Int {
        gate.lock(); defer { gate.unlock() }; return dropped
    }
    func stop() { player.stop(); engine.stop() }
}

/// Transport: ADB TCP forwarding to an Android app_process shell helper.
/// The phone's call-state HTTP endpoint is NOT involved in audio delivery.
final class PhoneAudioStream {
    private let gate = NSLock()
    private let microphoneQueue = MicrophonePCMQueue()
    private let microphone: LiveMacMicrophone
    private var closed = false
    private var socketFD: Int32 = -1
    private var helper: Process?
    private var setup: ADBAudioStreamSetup?
    private var active = false
    private let onEvent: (LiveAudioEvent) -> Void
    private let maxDuration: TimeInterval = 180

    init(onEvent: @escaping (LiveAudioEvent) -> Void) {
        self.onEvent = onEvent
        self.microphone = LiveMacMicrophone(queue: microphoneQueue)
    }

    var isActive: Bool {
        gate.lock(); defer { gate.unlock() }
        return active && !closed
    }

    func start(adb: String?, jar: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            run(adb: adb, jar: jar)
        }
    }

    func setMicrophone(_ enabled: Bool) throws {
        if enabled {
            guard isActive else { throw LiveAudioFailure.reason("AUDIO_NOT_ACTIVE") }
            try microphone.start()
        } else {
            microphone.stop()
        }
    }

    func stop() {
        gate.lock()
        closed = true
        let fd = socketFD
        gate.unlock()
        if fd >= 0 { _ = Darwin.shutdown(fd, Int32(SHUT_RDWR)) }
    }

    private var isClosed: Bool {
        gate.lock(); defer { gate.unlock() }; return closed
    }

    private func report(_ event: LiveAudioEvent) { onEvent(event) }

    private func run(adb: String?, jar: URL) {
        var reason = "STREAM_DISCONNECTED"
        defer {
            gate.lock()
            closed = true
            active = false
            let fd = socketFD
            socketFD = -1
            let process = helper
            helper = nil
            let session = setup
            setup = nil
            gate.unlock()
            if fd >= 0 {
                _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
                _ = Darwin.close(fd)
            }
            if let process, process.isRunning { process.terminate() }
            if let session { ADBInspector.closeAudioStream(session) }
            DispatchQueue.main.async { [weak self] in self?.microphone.stop() }
            report(.finished(reason))
        }

        report(.status("准备独立 ADB 音频通道……"))
        let prepared = ADBInspector.prepareAudioStream(at: adb, jar: jar)
        guard let target = prepared.setup else {
            reason = prepared.errorCode
            return
        }
        gate.lock()
        setup = target
        gate.unlock()
        if isClosed { reason = "USER_STOPPED"; return }

        let process = Process()
        process.executableURL = target.executable
        process.arguments = ["-s", target.serial, "shell",
            "CLASSPATH=/data/local/tmp/simai-audio-probe.jar app_process / dev.popowk.simai.probe.Main serve \(target.secret)"]
        // Never capture the helper's logs or expose its token/command line.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { reason = "ANDROID_HELPER_LAUNCH"; return }
        gate.lock()
        helper = process
        gate.unlock()

        report(.status("Android 音频进程已启动，等待握手……"))
        var fd: Int32 = -1
        let until = Date().addingTimeInterval(10)
        while Date() < until && !isClosed {
            fd = Self.connectLocal(port: target.localPort)
            if fd >= 0 { break }
            usleep(150_000)
        }
        guard fd >= 0 else { reason = isClosed ? "USER_STOPPED" : "AUDIO_PORT_TIMEOUT"; return }
        gate.lock()
        socketFD = fd
        gate.unlock()
        if isClosed { reason = "USER_STOPPED"; return }

        let hello = Array("SIMAI_AUDIO_1 \(target.secret)\n".utf8)
        guard Self.sendAll(fd, hello) else { reason = "AUDIO_HANDSHAKE_WRITE"; return }
        guard let ack = Self.readLine(fd), ack == "OK" else {
            reason = "AUDIO_HANDSHAKE_FAILED_OR_NO_CALL"
            return
        }

        let speaker: LiveMacSpeaker
        do { speaker = try LiveMacSpeaker() }
        catch { reason = "MAC_SPEAKER_START"; return }
        defer { speaker.stop() }

        gate.lock()
        active = true
        gate.unlock()
        report(.active)

        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            sendLoop(fd: fd, since: started)
        }
        var received = 0
        while !isClosed && Date().timeIntervalSince(started) < maxDuration {
            guard let frame = Self.readExact(fd, count: 640) else {
                reason = "AUDIO_REMOTE_CLOSED"
                break
            }
            speaker.feed(frame)
            received += 1
            if received % 50 == 0 {
                report(.metrics(received: received, sent: sentFrames(), dropped: speaker.droppedFrames()))
            }
        }
        if isClosed { reason = "USER_STOPPED" }
        else if Date().timeIntervalSince(started) >= maxDuration { reason = "SESSION_LIMIT_180S" }
        // Signal the writer immediately instead of letting a stalled send linger.
        gate.lock(); closed = true; gate.unlock()
        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
    }

    private var sent = 0
    private func sentFrames() -> Int {
        gate.lock(); defer { gate.unlock() }; return sent
    }

    private func sendLoop(fd: Int32, since: Date) {
        while !isClosed && Date().timeIntervalSince(since) < maxDuration {
            let data = microphoneQueue.nextFrame()
            guard Self.sendAll(fd, data) else { break }
            gate.lock(); sent += 1; gate.unlock()
            usleep(20_000)
        }
        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
    }

    private static func connectLocal(port: Int) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 { _ = Darwin.close(fd); return -1 }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.send(fd, base.advanced(by: sent),
                                    bytes.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 80 {
            var c: UInt8 = 0
            let n = Darwin.recv(fd, &c, 1, 0)
            if n <= 0 { return nil }
            if c == 10 { return String(bytes: bytes, encoding: .ascii) }
            if c < 32 || c > 126 { return nil }
            bytes.append(c)
        }
        return nil
    }

    private static func readExact(_ fd: Int32, count: Int) -> [UInt8]? {
        var frame = [UInt8](repeating: 0, count: count)
        let ok = frame.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let n = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? frame : nil
    }
}
#endif

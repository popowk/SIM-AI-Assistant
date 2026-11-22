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
    case handshakeAttempts(Int)
    case metrics(received: Int, sent: Int, dropped: Int, micUnderflows: Int, micOverflows: Int, txLate: Int, micBufferedMs: Int)
    case finished(String)
}

private enum LiveAudioFailure: Error {
    case reason(String)
}

private final class LiveMacMicrophone {
    private let queue: RealtimeAudioBuffer
    private var engine: AVAudioEngine?
    init(queue: RealtimeAudioBuffer) { self.queue = queue }

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

        // Reuse the conversion destination. Per-tap heap allocations and
        // array removeFirst() were causing unnecessary work in the microphone
        // callback. The input node invokes this tap serially.
        guard let converted = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: 4096) else {
            throw LiveAudioFailure.reason("MIC_BUFFER_UNAVAILABLE")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self, converter, converted] original, _ in
            guard let self else { return }
            converted.frameLength = 0
            var supplied = false
            var convertError: NSError?
            _ = converter.convert(to: converted, error: &convertError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return original
            }
            guard convertError == nil, converted.frameLength > 0,
                  let samples = converted.floatChannelData?[0] else { return }
            // Convert directly into the bounded ring without allocating and
            // removing arrays on each realtime audio callback.
            self.queue.appendFloatSamples(samples, count: Int(converted.frameLength))
        }
        queue.setCaptureEnabled(true)
        do {
            try audio.start()
            engine = audio
        } catch {
            queue.setCaptureEnabled(false)
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        // Discard buffered microphone speech immediately on mute/stop.
        queue.setCaptureEnabled(false)
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
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
        if pending >= 18 {
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
        // Count completion at actual playback, not merely buffer consumption,
        // so pending measures the speaker backlog more accurately.
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack,
                              completionHandler: { [weak self] in
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
    private let microphoneQueue = RealtimeAudioBuffer()
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
        // Only helper stdout is captured in memory to decode fixed error/stage
        // fields if the process exits before the socket starts. Raw stdout is
        // never logged, and stderr is discarded to protect device details.
        let helperOutput = Pipe()
        process.standardOutput = helperOutput
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { reason = "ANDROID_HELPER_LAUNCH"; return }
        gate.lock()
        helper = process
        gate.unlock()

        report(.status("Android 音频进程已启动，正在等待服务就绪……"))
        let hello = Array("SIMAI_AUDIO_1 \(target.secret)\n".utf8)
        let deadline = Date().addingTimeInterval(16)
        var fd: Int32 = -1
        var attempts = 0
        var ready = false
        reason = "AUDIO_HANDSHAKE_NO_RESPONSE"

        // An ADB forward can accept a local TCP connection *before* the Android
        // app_process has bound its loopback port. In that case the first socket
        // is closed immediately. Retry the whole handshake, not just connect().
        // Once a socket stays open, however, wait for its response: Android
        // may still be creating VOICE_DOWNLINK / injection audio tracks.
        while Date() < deadline && !isClosed {
            if !process.isRunning {
                let data = helperOutput.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data.prefix(4096), encoding: .utf8) ?? ""
                reason = PhoneAudioProtocol.helperExitStatus(output)
                break
            }
            let candidate = Self.connectLocal(port: target.localPort)
            if candidate < 0 {
                attempts += 1
                usleep(200_000)
                continue
            }
            attempts += 1
            gate.lock()
            socketFD = candidate
            gate.unlock()
            if isClosed {
                _ = Darwin.shutdown(candidate, Int32(SHUT_RDWR))
            } else if Self.sendAll(candidate, hello) {
                var partial: [UInt8] = []
                attemptHandshake: while Date() < deadline && !isClosed {
                    switch Self.readHandshake(candidate, partial: &partial) {
                    case .line(let response):
                        let parsed = PhoneAudioProtocol.handshakeStatus(response)
                        if parsed == "OK" {
                            fd = candidate
                            ready = true
                            reason = "STREAM_DISCONNECTED"
                        } else {
                            reason = parsed
                        }
                        break attemptHandshake
                    case .timeout:
                        // The helper accepted the socket but is still initializing;
                        // never open a second connection just because it is slow.
                        continue
                    case .closed:
                        reason = "AUDIO_HANDSHAKE_NO_RESPONSE"
                        break attemptHandshake
                    case .invalid:
                        reason = "AUDIO_HANDSHAKE_UNEXPECTED"
                        break attemptHandshake
                    }
                }
            } else {
                reason = "AUDIO_HANDSHAKE_WRITE"
            }
            if ready { break }
            gate.lock()
            if socketFD == candidate { socketFD = -1 }
            gate.unlock()
            _ = Darwin.shutdown(candidate, Int32(SHUT_RDWR))
            _ = Darwin.close(candidate)
            // Explicit Android errors and malformed responses must not be
            // disguised by retries; only early EOF / write failure can recover.
            if reason != "AUDIO_HANDSHAKE_NO_RESPONSE" &&
               reason != "AUDIO_HANDSHAKE_WRITE" { break }
            if attempts % 5 == 0 {
                report(.status("Android 音频服务尚未就绪，重试握手（\(attempts) 次）……"))
            }
            usleep(250_000)
        }
        report(.handshakeAttempts(attempts))
        guard ready && fd >= 0 else {
            if isClosed { reason = "USER_STOPPED" }
            return
        }
        report(.status("实时音频服务握手完成（\(attempts) 次连接尝试）"))

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
                reportMetrics(received: received, speaker: speaker)
            }
        }
        reportMetrics(received: received, speaker: speaker)
        if isClosed { reason = "USER_STOPPED" }
        else if Date().timeIntervalSince(started) >= maxDuration { reason = "SESSION_LIMIT_180S" }
        // Signal the writer immediately instead of letting a stalled send linger.
        gate.lock(); closed = true; gate.unlock()
        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
    }

    private var sent = 0
    private var txLateFrames = 0
    private func sentStatistics() -> (sent: Int, late: Int) {
        gate.lock(); defer { gate.unlock() }
        return (sent, txLateFrames)
    }

    private func reportMetrics(received: Int, speaker: LiveMacSpeaker) {
        let mic = microphoneQueue.statistics()
        let sending = sentStatistics()
        report(.metrics(received: received, sent: sending.sent,
                        dropped: speaker.droppedFrames(),
                        micUnderflows: mic.underflowFrames,
                        micOverflows: mic.overflowFrames,
                        txLate: sending.late,
                        micBufferedMs: mic.bufferedMilliseconds))
    }

    private func sendLoop(fd: Int32, since: Date) {
        var pacing = AudioFramePacer()
        while !isClosed && Date().timeIntervalSince(since) < maxDuration {
            let waitNs = pacing.waitNanoseconds(now: DispatchTime.now().uptimeNanoseconds)
            if waitNs > 0 {
                // The system may wake slightly early or late. Absolute
                // deadlines prevent slow ADB writes from accumulating drift.
                usleep(useconds_t(max(100, min(20_000, waitNs / 1_000))))
                continue
            }
            let data = microphoneQueue.nextFrame()
            guard Self.sendAll(fd, data) else { break }
            gate.lock()
            sent += 1
            txLateFrames = pacing.lateFrames
            gate.unlock()
            // Do not add a 20ms sleep *after* the blocking socket write.
            // Next iteration is timed against the monotonic deadline.
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

    private enum HandshakeRead {
        case line(String)
        case timeout
        case closed
        case invalid
    }

    private static func readHandshake(_ fd: Int32, partial: inout [UInt8]) -> HandshakeRead {
        while partial.count < 80 {
            var c: UInt8 = 0
            let n = Darwin.recv(fd, &c, 1, 0)
            if n == 0 { return .closed }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    return .timeout
                }
                return .closed
            }
            if c == 10 {
                guard let text = String(bytes: partial, encoding: .ascii) else { return .invalid }
                return .line(text)
            }
            guard c >= 32 && c <= 126 else { return .invalid }
            partial.append(c)
        }
        return .invalid
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

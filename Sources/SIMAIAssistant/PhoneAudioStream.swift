#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Darwin
import SIMAICore

/// One preview call is limited to 180 seconds. Raw samples stay in process
/// memory only; neither the audio nor the per-session token is logged or saved.
enum LiveAudioEvent {
    case status(String)
    case active
    case handshakeAttempts(Int)
    case metrics(received: Int, sent: Int, dropped: Int, micUnderflows: Int, micOverflows: Int, txLate: Int, micBufferedMs: Int, voiceRouteDropped: Int, monitorRendered: Int, virtualRendered: Int)
    case aiReturnMetrics(captured: Int, monitorDropped: Int, uplinkUnderflow: Int, peakRMS: Double)
    case downlinkSignal(peakRMS: Double)
    case callerSilenceLimit
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

/// Continuously pull PCM from a bounded ring buffer instead of scheduling
/// thousands of small AVAudioPlayerNode buffers. Those completion callbacks
/// could stop draining under CoreAudio device routing and drop almost every
/// 20ms phone frame even while the ADB stream remained healthy.
private final class LiveMacSpeaker {
    // Use the macOS HAL output unit directly. On some virtual/physical devices
    // AVAudioEngine.start() succeeded but AVAudioSourceNode was never pulled,
    // silently dropping thousands of telephone frames.
    private let gate = NSLock()
    private let capacity = 320 * 50
    private var samples = [Float](repeating: 0, count: 320 * 50)
    private var readIndex = 0
    private var writeIndex = 0
    private var queued = 0
    private var dropped = 0
    private var rendered = 0
    private var stopped = false
    private var resamplePhase = 0.0
    private var currentSample: Float = 0
    private var nextSample: Float = 0
    private var primed = false
    private var unit: AudioUnit?
    private let outputRate: Double

    init(deviceID: AudioDeviceID? = nil) throws {
        let device: AudioDeviceID
        if let deviceID {
            device = deviceID
        } else {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var selected: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                &size, &selected) == noErr, selected != 0 else {
                throw LiveAudioFailure.reason("SPEAKER_NO_DEFAULT_DEVICE")
            }
            device = selected
        }
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nominal: Float64 = 48000
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &rateAddr, 0, nil,
                                          &rateSize, &nominal) == noErr,
              nominal >= 8000 else {
            throw LiveAudioFailure.reason("SPEAKER_RATE_UNAVAILABLE")
        }
        outputRate = nominal

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw LiveAudioFailure.reason("SPEAKER_HAL_UNAVAILABLE")
        }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr,
              let instance else {
            throw LiveAudioFailure.reason("SPEAKER_HAL_CREATE")
        }
        do {
            var enableOutput: UInt32 = 1
            guard AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &enableOutput,
                                       UInt32(MemoryLayout<UInt32>.size)) == noErr else {
                throw LiveAudioFailure.reason("SPEAKER_HAL_ENABLE")
            }
            var disableInput: UInt32 = 0
            _ = AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &disableInput,
                                     UInt32(MemoryLayout<UInt32>.size))
            var selected = device
            guard AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &selected,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw LiveAudioFailure.reason("SPEAKER_HAL_SELECT_DEVICE")
            }
            var actual: AudioDeviceID = 0
            var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioUnitGetProperty(instance, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0,
                                       &actual, &actualSize) == noErr, actual == device else {
                throw LiveAudioFailure.reason("SPEAKER_HAL_DEVICE_MISMATCH")
            }
            let channels: UInt32 = 2
            var format = AudioStreamBasicDescription(
                mSampleRate: nominal,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: channels * 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: channels * 4,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0)
            guard AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
                throw LiveAudioFailure.reason("SPEAKER_HAL_FORMAT")
            }
            var callback = AURenderCallbackStruct(
                inputProc: { refCon, _, _, _, frameCount, ioData in
                    guard let ioData else { return noErr }
                    return Unmanaged<LiveMacSpeaker>.fromOpaque(refCon)
                        .takeUnretainedValue().render(frames: Int(frameCount), to: ioData)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            guard AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
                  AudioUnitInitialize(instance) == noErr else {
                throw LiveAudioFailure.reason("SPEAKER_HAL_CALLBACK")
            }
            self.unit = instance
            guard AudioOutputUnitStart(instance) == noErr else {
                throw LiveAudioFailure.reason("SPEAKER_HAL_START")
            }
        } catch {
            _ = AudioOutputUnitStop(instance)
            _ = AudioUnitUninitialize(instance)
            _ = AudioComponentInstanceDispose(instance)
            unit = nil
            throw error
        }
    }

    private func nextQueuedSample() -> Float {
        guard queued > 0 else { return 0 }
        let sample = samples[readIndex]
        readIndex = (readIndex + 1) % capacity
        queued -= 1
        return sample
    }

    private func render(frames: Int, to data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        gate.lock()
        if stopped {
            for buffer in buffers {
                buffer.mData?.initializeMemory(as: UInt8.self,
                                               repeating: 0, count: Int(buffer.mDataByteSize))
            }
            gate.unlock()
            return noErr
        }
        let step = 16000.0 / outputRate
        for frame in 0..<frames {
            if !primed {
                currentSample = nextQueuedSample()
                nextSample = nextQueuedSample()
                primed = true
            }
            let signalAvailable = queued > 0 || currentSample != 0 || nextSample != 0
            let value = currentSample + Float(resamplePhase) * (nextSample - currentSample)
            for buffer in buffers {
                guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0 && (frame + 1) * channels * 4 <= Int(buffer.mDataByteSize) else { continue }
                for channel in 0..<channels { ptr[frame * channels + channel] = value }
            }
            if signalAvailable { rendered += 1 }
            resamplePhase += step
            while resamplePhase >= 1 {
                currentSample = nextSample
                nextSample = nextQueuedSample()
                resamplePhase -= 1
            }
        }
        gate.unlock()
        return noErr
    }

    func feed(_ bytes: [UInt8]) {
        guard bytes.count == 640 else { return }
        gate.lock()
        defer { gate.unlock() }
        guard !stopped else { return }
        if queued + 320 > capacity {
            readIndex = (readIndex + 320) % capacity
            queued -= 320
            dropped += 1
        }
        for i in 0..<320 {
            let value = UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8)
            samples[writeIndex] = Float(Int16(bitPattern: value)) / 32768.0
            writeIndex = (writeIndex + 1) % capacity
        }
        queued += 320
    }

    func droppedFrames() -> Int {
        gate.lock(); defer { gate.unlock() }
        return dropped
    }

    func renderedFrames() -> Int {
        gate.lock(); defer { gate.unlock() }
        return Int(Double(rendered) / (outputRate * 0.02))
    }

    func stop() {
        gate.lock()
        stopped = true
        queued = 0
        let currentUnit = unit
        unit = nil
        gate.unlock()
        if let currentUnit {
            _ = AudioOutputUnitStop(currentUnit)
            _ = AudioUnitUninitialize(currentUnit)
            _ = AudioComponentInstanceDispose(currentUnit)
        }
    }
}

/// Separate, opt-in return path for ChatGPT output. BlackHole 16ch must be
/// selected as the ChatGPT playback device. The monitor goes only to an
/// explicitly chosen physical output; the phone uplink is off by default.
/// Samples live in fixed in-memory rings and are not written to logs/disk.
private final class LiveAIReplyCapture {
    let phoneQueue = RealtimeAudioBuffer()
    private let monitorQueue = RealtimeAudioBuffer()
    private let engine = AVAudioEngine()
    private let monitor: LiveMacSpeaker
    private let lock = NSLock()
    private var stopped = false
    private var capturedSamples = 0
    private var peakRMS = 0.0

    init(virtualInput: AudioDeviceID, physicalOutput: AudioDeviceID) throws {
        self.monitor = try LiveMacSpeaker(deviceID: physicalOutput)
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            monitor.stop()
            throw LiveAudioFailure.reason("AI_RETURN_NO_INPUT_UNIT")
        }
        var selected = virtualInput
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &selected, size) == noErr else {
            monitor.stop()
            throw LiveAudioFailure.reason("AI_RETURN_INPUT_SELECT_FAILED")
        }
        var actual: AudioDeviceID = 0
        var actualSize = size
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &actual, &actualSize) == noErr,
              actual == selected else {
            monitor.stop()
            throw LiveAudioFailure.reason("AI_RETURN_INPUT_MISMATCH")
        }

        let source = input.inputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let converted = AVAudioPCMBuffer(pcmFormat: target,
                                               frameCapacity: 4096) else {
            monitor.stop()
            throw LiveAudioFailure.reason("AI_RETURN_FORMAT_UNSUPPORTED")
        }
        converter.channelMap = [0]
        // Do not even buffer a caller-facing PCM frame until separately
        // authorized; monitoring uses its own independent queue.
        phoneQueue.setCaptureEnabled(false)
        monitorQueue.setCaptureEnabled(true)
        // Only this named virtual device is tapped. If it is set as the
        // macOS system output, other applications may ALSO feed this device.
        // User is warned to silence other apps before enabling PSTN uplink.
        // BlackHole 16ch is a multichannel virtual device. Previously
        // converter.channelMap=[0] silently lost GPT if WebKit wrote stereo
        // content to another channel pair. Choose the loudest real source
        // channel from the virtual device before downmixing; this has no
        // effect on the Mac's global output routing.
        var selectedSourceChannel = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: source) {
            [weak self, converter, converted] buffer, _ in
            guard let self else { return }
            if let channels = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                let n = min(Int(buffer.format.channelCount), 16)
                if count > 0 && n > 1 {
                    var bestIndex = selectedSourceChannel
                    var bestPower = 0.0
                    var selectedPower = 0.0
                    let stride = Int(buffer.format.channelCount)
                    for channel in 0..<n {
                        var power = 0.0
                        for frame in 0..<count {
                            let sample = buffer.format.isInterleaved
                                ? channels[0][frame * stride + channel]
                                : channels[channel][frame]
                            power += Double(sample) * Double(sample)
                        }
                        if channel == selectedSourceChannel { selectedPower = power }
                        if power > bestPower {
                            bestPower = power
                            bestIndex = channel
                        }
                    }
                    // Move only if the selected channel is nearly silent
                    // compared with another active one; stereo voices must
                    // not flip channels on every small volume fluctuation.
                    if bestIndex != selectedSourceChannel &&
                       bestPower / Double(count) > 0.000_009 &&
                       selectedPower < bestPower * 0.08 {
                        selectedSourceChannel = bestIndex
                        converter.channelMap = [NSNumber(value: bestIndex)]
                    }
                }
            }
            converted.frameLength = 0
            var supplied = false
            var err: NSError?
            _ = converter.convert(to: converted, error: &err) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, converted.frameLength > 0,
                  let data = converted.floatChannelData?[0] else { return }
            let count = Int(converted.frameLength)
            var power = 0.0
            for i in 0..<count {
                let v = Double(data[i])
                power += v * v
            }
            let rms = sqrt(power / Double(count))
            self.phoneQueue.appendFloatSamples(data, count: count)
            self.monitorQueue.appendFloatSamples(data, count: count)
            self.lock.lock()
            self.capturedSamples += count
            self.peakRMS = max(self.peakRMS, rms)
            self.lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            phoneQueue.setCaptureEnabled(false)
            monitorQueue.setCaptureEnabled(false)
            monitor.stop()
            throw LiveAudioFailure.reason("AI_RETURN_CAPTURE_START")
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.monitorLoop()
        }
    }

    private func monitorLoop() {
        var pacer = AudioFramePacer()
        while true {
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            if isStopped { break }
            let wait = pacer.waitNanoseconds(now: DispatchTime.now().uptimeNanoseconds)
            if wait > 0 {
                usleep(useconds_t(max(100, min(20_000, wait / 1_000))))
                continue
            }
            monitor.feed(monitorQueue.nextFrame())
        }
    }

    func setPhoneForwarding(_ enabled: Bool) {
        // Clears old speech on every on/off transition. No pre-consent
        // buffered audio can leak when the user enables forwarding later.
        phoneQueue.setCaptureEnabled(enabled)
    }
    func nextPhoneFrame() -> [UInt8] { phoneQueue.nextFrame() }

    func statistics() -> (captured: Int, monitorDropped: Int, uplinkUnderflow: Int, peakRMS: Double) {
        lock.lock()
        let samples = capturedSamples
        let peak = peakRMS
        lock.unlock()
        return (samples / 320, monitor.droppedFrames(), phoneQueue.statistics().underflowFrames, peak)
    }

    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        phoneQueue.setCaptureEnabled(false)
        monitorQueue.setCaptureEnabled(false)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        monitor.stop()
    }
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
    private var chatGPTVirtualMic: LiveMacSpeaker?
    private var aiReplyCapture: LiveAIReplyCapture?
    private var aiReplyToPhone = false
    // The phone downlink and GPT return were both played through the Mac's
    // physical speaker. During AI mode only the GPT return is monitored by
    // default; the caller still reaches BlackHole 2ch and GPT unchanged.
    private var callerMonitorEnabled = true
    private let physicalMonitorOutput: AudioDeviceID?
    private let localReception: LocalReceptionEngine?
    private let localCapture: LocalCallCapture?
    private let silenceSeconds: Int
    private var setup: ADBAudioStreamSetup?
    private var active = false
    private let onEvent: (LiveAudioEvent) -> Void
    private let maxDuration: TimeInterval = 180

    init(physicalMonitorOutput: AudioDeviceID? = nil,
         localReception: LocalReceptionEngine? = nil,
         localCapture: LocalCallCapture? = nil,
         silenceSeconds: Int = 0,
         onEvent: @escaping (LiveAudioEvent) -> Void) {
        self.physicalMonitorOutput = physicalMonitorOutput
        self.localReception = localReception
        self.localCapture = localCapture
        self.silenceSeconds = max(0, min(60, silenceSeconds))
        self.onEvent = onEvent
        self.microphone = LiveMacMicrophone(queue: microphoneQueue)
    }

    var isActive: Bool {
        gate.lock(); defer { gate.unlock() }
        return active && !closed
    }

    func setCallerMonitorEnabled(_ enabled: Bool) {
        gate.lock()
        callerMonitorEnabled = enabled
        gate.unlock()
    }

    func start(adb: String?, jar: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            run(adb: adb, jar: jar)
        }
    }

    func setMicrophone(_ enabled: Bool) throws {
        if enabled && localReception != nil { throw LiveAudioFailure.reason("LOCAL_RECEPTION_EXCLUSIVE") }
        if enabled {
            guard isActive else { throw LiveAudioFailure.reason("AUDIO_NOT_ACTIVE") }
            gate.lock()
            let aiForwarding = aiReplyToPhone
            gate.unlock()
            guard !aiForwarding else { throw LiveAudioFailure.reason("AI_RETURN_ALREADY_FORWARDING") }
            try microphone.start()
        } else {
            microphone.stop()
        }
    }

    /// A silent low-amplitude synthetic signal proves that each selected HAL
    /// output actually pulls PCM before the app answers an inbound telephone call.
    /// It does not prove that ChatGPT itself heard or understood any speech.
    static func preflightOutputs(physicalOutputID: AudioDeviceID?) -> String {
        guard let physicalOutputID else { return "PREFLIGHT_PHYSICAL_MISSING" }
        guard let virtual = AudioInspector().inspect().devices.first(where: {
            $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
        }), let virtualID = UInt32(virtual.id) else {
            return "PREFLIGHT_VIRTUAL_MISSING"
        }
        let values = (0..<320).map { i -> Int16 in
            Int16(300 * sin(Double(i) * 2.0 * .pi * 440.0 / 16000.0))
        }
        let frame: [UInt8] = values.flatMap { v in
            let bits = UInt16(bitPattern: v)
            return [UInt8(truncatingIfNeeded: bits),
                    UInt8(truncatingIfNeeded: bits >> 8)]
        }
        for (name, device) in [("PHYSICAL", physicalOutputID),
                               ("BLACKHOLE2", AudioDeviceID(virtualID))] {
            do {
                let speaker = try LiveMacSpeaker(deviceID: device)
                for _ in 0..<12 {
                    speaker.feed(frame)
                    usleep(20_000)
                }
                usleep(80_000)
                let pulled = speaker.renderedFrames()
                speaker.stop()
                if pulled < 4 { return "PREFLIGHT_\(name)_NOT_RENDERING" }
            } catch LiveAudioFailure.reason(let code) {
                return "PREFLIGHT_\(name)_\(code)"
            } catch {
                return "PREFLIGHT_\(name)_START_FAILED"
            }
        }
        return "PREFLIGHT_OK"
    }

    /// Opt-in receive-only ChatGPT Voice input; never routes AI audio to caller.
    func setChatGPTInputRouting(_ enabled: Bool) throws {
        if enabled && localReception != nil { throw LiveAudioFailure.reason("LOCAL_RECEPTION_EXCLUSIVE") }
        if !enabled {
            gate.lock()
            let old = chatGPTVirtualMic
            chatGPTVirtualMic = nil
            gate.unlock()
            old?.stop()
            return
        }
        guard isActive else { throw LiveAudioFailure.reason("VOICE_ROUTE_CALL_INACTIVE") }
        // Never fall back to the default output or a real microphone.
        let matches = AudioInspector().inspect().devices.filter {
            $0.displayName.caseInsensitiveCompare("BlackHole 2ch") == .orderedSame
        }
        guard matches.count == 1, let rawID = UInt32(matches[0].id) else {
            throw LiveAudioFailure.reason("VOICE_ROUTE_BLACKHOLE_MISSING")
        }
        let output = try LiveMacSpeaker(deviceID: AudioDeviceID(rawID))
        gate.lock()
        let available = active && !closed
        let previous = chatGPTVirtualMic
        if available { chatGPTVirtualMic = output }
        gate.unlock()
        guard available else {
            output.stop()
            throw LiveAudioFailure.reason("VOICE_ROUTE_CALL_ENDED")
        }
        previous?.stop()
    }

    /// The monitor is safe by default: AI audio can be heard locally but
    /// cannot reach the phone unless a second distinct consent action occurs.
    func setAIReplyMonitoring(_ enabled: Bool, physicalOutputID: AudioDeviceID? = nil) throws {
        if enabled && localReception != nil { throw LiveAudioFailure.reason("LOCAL_RECEPTION_EXCLUSIVE") }
        if !enabled {
            gate.lock()
            aiReplyToPhone = false
            let previous = aiReplyCapture
            aiReplyCapture = nil
            gate.unlock()
            previous?.stop()
            return
        }
        guard isActive else { throw LiveAudioFailure.reason("AI_RETURN_CALL_INACTIVE") }
        let devices = AudioInspector().inspect().devices
        let virtual = devices.filter {
            $0.displayName.caseInsensitiveCompare("BlackHole 16ch") == .orderedSame
        }
        guard virtual.count == 1, let virtualID = UInt32(virtual[0].id) else {
            throw LiveAudioFailure.reason("AI_RETURN_BLACKHOLE_16CH_MISSING")
        }
        guard let outputID = physicalOutputID ?? physicalMonitorOutput,
              let outputDevice = devices.first(where: { UInt32($0.id) == outputID }),
              !outputDevice.displayName.localizedCaseInsensitiveContains("BlackHole"),
              !outputDevice.displayName.localizedCaseInsensitiveContains("aggregate"),
              !outputDevice.displayName.localizedCaseInsensitiveContains("multi-output"),
              outputID != virtualID else {
            throw LiveAudioFailure.reason("AI_RETURN_PHYSICAL_OUTPUT_REQUIRED")
        }
        let capture = try LiveAIReplyCapture(virtualInput: AudioDeviceID(virtualID),
                                             physicalOutput: AudioDeviceID(outputID))
        gate.lock()
        let available = active && !closed
        let previous = aiReplyCapture
        if available {
            aiReplyToPhone = false
            aiReplyCapture = capture
        }
        gate.unlock()
        guard available else {
            capture.stop()
            throw LiveAudioFailure.reason("AI_RETURN_CALL_ENDED")
        }
        previous?.stop()
    }

    func setAIReplyToPhone(_ enabled: Bool) throws {
        if enabled && localReception != nil { throw LiveAudioFailure.reason("LOCAL_RECEPTION_EXCLUSIVE") }
        guard isActive else { throw LiveAudioFailure.reason("AI_RETURN_CALL_INACTIVE") }
        if enabled {
            gate.lock()
            let ready = aiReplyCapture != nil
            gate.unlock()
            guard ready else { throw LiveAudioFailure.reason("AI_RETURN_MONITOR_REQUIRED") }
            // Mutually exclusive with the user's Mac microphone. Do not mix
            // desktop output, microphone and AI speech into one PSTN uplink.
            microphone.stop()
        }
        gate.lock()
        let capture = aiReplyCapture
        if !enabled { aiReplyToPhone = false }
        gate.unlock()
        capture?.setPhoneForwarding(enabled)
        if enabled {
            gate.lock()
            if aiReplyCapture === capture && !closed { aiReplyToPhone = true }
            gate.unlock()
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
            let virtualMic = chatGPTVirtualMic
            chatGPTVirtualMic = nil
            let aiCapture = aiReplyCapture
            aiReplyCapture = nil
            aiReplyToPhone = false
            let session = setup
            setup = nil
            gate.unlock()
            if fd >= 0 {
                _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
                _ = Darwin.close(fd)
            }
            localReception?.endCall()
            virtualMic?.stop()
            aiCapture?.stop()
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

        // Local reception connects ASR and pre-rendered TTS directly to
        // cellular PCM. No physical or virtual Mac sound device is needed.
        let speaker: LiveMacSpeaker?
        if let localReception {
            guard localReception.beginCall(capture: localCapture) else { reason = "LOCAL_ASR_NOT_READY"; return }
            speaker = nil
        } else {
            do {
                if physicalMonitorOutput == nil && AudioInspector().inspect().devices.contains(where: {
                    $0.isDefaultOutput && $0.displayName.localizedCaseInsensitiveContains("BlackHole")
                }) { throw LiveAudioFailure.reason("PHONE_PHYSICAL_OUTPUT_REQUIRED") }
                speaker = try LiveMacSpeaker(deviceID: physicalMonitorOutput)
            } catch { reason = "MAC_SPEAKER_START"; return }
        }
        defer { speaker?.stop() }

        gate.lock()
        active = true
        gate.unlock()
        report(.active)

        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            sendLoop(fd: fd, since: started)
        }
        var received = 0
        var downlinkPeakRMS = 0.0
        var quietFrames = 0
        var audibleFrames = 0
        while !isClosed && Date().timeIntervalSince(started) < maxDuration {
            guard let frame = Self.readExact(fd, count: 640) else {
                reason = "AUDIO_REMOTE_CLOSED"
                break
            }
            // Compute a non-content audio level only. No voice or samples
            // are retained in diagnostics or transmitted outside this app.
            var power = 0.0
            for offset in stride(from: 0, to: frame.count, by: 2) {
                let sample = UInt16(frame[offset]) | (UInt16(frame[offset + 1]) << 8)
                let normalized = Double(Int16(bitPattern: sample)) / 32768.0
                power += normalized * normalized
            }
            let rms = sqrt(power / 320.0)
            downlinkPeakRMS = max(downlinkPeakRMS, rms)
            // PCM level heuristic (not semantic VAD). Count received 20ms frames,
            // not network downtime, and require consecutive audible frames to reset.
            if silenceSeconds > 0 {
                quietFrames += 1
                audibleFrames = rms >= 0.008 ? audibleFrames + 1 : 0
                if audibleFrames >= 5 { quietFrames = 0 }
                if quietFrames == silenceSeconds * 50 { report(.callerSilenceLimit) }
            }
            gate.lock()
            let callerMonitor = callerMonitorEnabled
            let virtualMic = chatGPTVirtualMic
            gate.unlock()
            if let localReception {
                if !localReception.isReady { reason = "LOCAL_ASR_FAILED"; break }
                localCapture?.append(frame, uplink: false)
                localReception.feed(frame)
            } else {
                if callerMonitor { speaker?.feed(frame) }
                virtualMic?.feed(frame)
            }
            received += 1
            if received % 50 == 0 {
                report(.downlinkSignal(peakRMS: downlinkPeakRMS))
                reportMetrics(received: received, speaker: speaker)
            }
        }
        report(.downlinkSignal(peakRMS: downlinkPeakRMS))
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

    private func reportMetrics(received: Int, speaker: LiveMacSpeaker?) {
        let mic = microphoneQueue.statistics()
        let sending = sentStatistics()
        gate.lock()
        let capture = aiReplyCapture
        gate.unlock()
        if let capture {
            let stats = capture.statistics()
            report(.aiReturnMetrics(captured: stats.captured,
                                    monitorDropped: stats.monitorDropped,
                                    uplinkUnderflow: stats.uplinkUnderflow,
                                    peakRMS: stats.peakRMS))
        }
        report(.metrics(received: received, sent: sending.sent,
                        dropped: speaker?.droppedFrames() ?? 0,
                        micUnderflows: mic.underflowFrames,
                        micOverflows: mic.overflowFrames,
                        txLate: sending.late,
                        micBufferedMs: mic.bufferedMilliseconds,
                        voiceRouteDropped: virtualMicDroppedFrames(),
                        monitorRendered: speaker?.renderedFrames() ?? 0,
                        virtualRendered: virtualMicRenderedFrames()))
    }

    private func virtualMicDroppedFrames() -> Int {
        gate.lock()
        let output = chatGPTVirtualMic
        gate.unlock()
        return output?.droppedFrames() ?? 0
    }

    private func virtualMicRenderedFrames() -> Int {
        gate.lock()
        let output = chatGPTVirtualMic
        gate.unlock()
        return output?.renderedFrames() ?? 0
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
            gate.lock()
            let forwardAI = aiReplyToPhone
            let capture = aiReplyCapture
            gate.unlock()
            let data: [UInt8]
            if let localReception {
                data = localReception.nextFrame()
            } else if forwardAI, let capture {
                data = capture.nextPhoneFrame()
            } else {
                data = microphoneQueue.nextFrame()
            }
            guard Self.sendAll(fd, data) else { break }
            localCapture?.append(data, uplink: true)
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

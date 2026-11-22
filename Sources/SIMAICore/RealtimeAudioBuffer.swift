import Foundation

/// A bounded 16 kHz mono microphone FIFO. Raw audio lives only in memory.
/// It is never copied into diagnostics. Mutex protects short producer/consumer
/// operations; the storage remains fixed-size for the lifetime of the stream.
public final class RealtimeAudioBuffer {
    public static let samplesPerFrame = 320
    public static let bytesPerFrame = 640
    public static let capacityFrames = 12

    public struct Stats: Equatable {
        public let underflowFrames: Int
        public let overflowFrames: Int
        public let bufferedMilliseconds: Int
        public let peakBufferedMilliseconds: Int
    }

    private let gate = NSLock()
    private var storage = [Int16](repeating: 0, count: 320 * 12)
    private var readIndex = 0
    private var filled = 0
    private var enabled = false
    private var underflowFrames = 0
    private var overflowFrames = 0
    private var peakBufferedSamples = 0

    public init() {}

    public func setCaptureEnabled(_ value: Bool) {
        gate.lock()
        enabled = value
        readIndex = 0
        filled = 0
        if value {
            underflowFrames = 0
            overflowFrames = 0
            peakBufferedSamples = 0
        }
        gate.unlock()
    }

    /// Convert and enqueue Float32 tap samples without creating a temporary
    /// Int16 array in the AVAudioEngine realtime callback.
    public func appendFloatSamples(_ pointer: UnsafePointer<Float>, count: Int) {
        guard count > 0, count <= 16_384 else { return }
        gate.lock()
        defer { gate.unlock() }
        guard enabled else { return }
        for index in 0..<count {
            let sample = pointer[index]
            let safe = sample.isFinite ? max(-0.6, min(0.6, sample * 0.55)) : 0
            push(Int16(safe * 32767))
        }
    }

    /// Test input and a possible future provider of preconverted mono PCM.
    public func appendPCM16(_ samples: [Int16]) {
        gate.lock()
        defer { gate.unlock() }
        guard enabled else { return }
        for sample in samples { push(sample) }
    }

    /// Called with the mutex already held.
    private func push(_ sample: Int16) {
        if filled == storage.count {
            // Avoid unbounded voice latency: drop the oldest 20 ms, then
            // preserve the latest captured speech.
            readIndex = (readIndex + Self.samplesPerFrame) % storage.count
            filled -= Self.samplesPerFrame
            overflowFrames += 1
        }
        let target = (readIndex + filled) % storage.count
        storage[target] = sample
        filled += 1
        peakBufferedSamples = max(peakBufferedSamples, filled)
    }

    /// 20 ms PCM16 LE. If the microphone is off, sends silence without
    /// inflating the underflow counter. If input is late, records an underflow.
    public func nextFrame() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.bytesPerFrame)
        gate.lock()
        defer { gate.unlock() }
        guard enabled else { return bytes }
        guard filled >= Self.samplesPerFrame else {
            underflowFrames += 1
            return bytes
        }
        for i in 0..<Self.samplesPerFrame {
            let bits = UInt16(bitPattern: storage[(readIndex + i) % storage.count])
            bytes[i * 2] = UInt8(truncatingIfNeeded: bits)
            bytes[i * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
        }
        readIndex = (readIndex + Self.samplesPerFrame) % storage.count
        filled -= Self.samplesPerFrame
        return bytes
    }

    public func statistics() -> Stats {
        gate.lock()
        defer { gate.unlock() }
        return Stats(underflowFrames: underflowFrames,
                     overflowFrames: overflowFrames,
                     bufferedMilliseconds: filled * 1000 / 16_000,
                     peakBufferedMilliseconds: peakBufferedSamples * 1000 / 16_000)
    }
}

/// A monotonic 20 ms uplink scheduler. Scheduling from the previous deadline,
/// not from the previous socket write's end, prevents gradual drift. When a
/// socket stalls by >1 frame, skip missed deadlines instead of burst-sending
/// stale frames to the phone after it resumes.
public struct AudioFramePacer {
    public static let intervalNanoseconds: UInt64 = 20_000_000
    public private(set) var lateFrames = 0
    private var nextDeadline: UInt64?

    public init() {}

    /// Call before each send. A nonzero result means sleep and retry without
    /// dequeueing a sample frame yet.
    public mutating func waitNanoseconds(now: UInt64) -> UInt64 {
        guard let next = nextDeadline else {
            nextDeadline = now + Self.intervalNanoseconds
            return 0
        }
        if now < next { return next - now }
        let behind = now - next
        if behind >= Self.intervalNanoseconds {
            lateFrames += Int(behind / Self.intervalNanoseconds)
            nextDeadline = now + Self.intervalNanoseconds
        } else {
            nextDeadline = next + Self.intervalNanoseconds
        }
        return 0
    }
}

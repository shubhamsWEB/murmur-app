import Foundation

/// The last moment of sound before the dictation key goes down, kept while the microphone stays ready between
/// dictations. People start speaking as they press the key (often a little before), and a recording that starts at
/// the press begins mid-word: "Sudoku" was heard as "Doku", "Solve" as "So all". With this, the recording starts
/// half a second earlier, so the first word arrives whole.
///
/// A fixed-size ring: the newest `capacity` samples, oldest first when read.
struct PreRoll {
    private(set) var capacity: Int
    private var buffer: [Float]
    private var next = 0
    private var filled = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        buffer = [Float](repeating: 0, count: self.capacity)
    }

    /// Adds sound; only the newest `capacity` samples are kept.
    mutating func append(_ samples: [Float]) {
        guard capacity > 0, !samples.isEmpty else { return }
        // More than fits: only its end matters.
        let tail = samples.count > capacity ? samples[(samples.count - capacity)...] : samples[...]
        for value in tail {
            buffer[next] = value
            next = (next + 1) % capacity
        }
        filled = min(capacity, filled + tail.count)
    }

    /// What's kept, oldest first.
    func contents() -> [Float] {
        guard filled > 0 else { return [] }
        if filled < capacity { return Array(buffer[0..<filled]) }
        return Array(buffer[next...] + buffer[..<next])
    }

    /// Forgets what's kept (the recording that used it has started, or the microphone changed).
    mutating func clear() {
        next = 0
        filled = 0
    }

    /// A new size (the microphone's sample rate changed); what was kept is dropped.
    mutating func resize(_ capacity: Int) {
        guard capacity != self.capacity else { clear(); return }
        self = PreRoll(capacity: capacity)
    }
}

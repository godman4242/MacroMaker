import Testing

/// All suites that swap a GLOBAL seam (`EventSynthesizer.eventPoster`,
/// `MacroRecorder.tapBuilder`, `Persistence.writer`, …) run one at a time.
/// The library's `.serialized` only orders tests WITHIN one suite, leaving two
/// seam-swapping suites free to race each other (a drag test once read the
/// wrong suite's poster and failed on a re-run). A test-scoping trait gives
/// us the cross-suite gate: `provideScope` wraps each gated test in the one
/// process-wide gate below, so every suite applying `.seamSerialized` runs
/// serially against every other one.
struct SeamSerialized: TestTrait, SuiteTrait, TestScoping {
    /// Suite traits recurse so sub-suites inherit the gate.
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await SeamGate.shared.run(function)
    }
}

/// One process-wide gate: a busy flag plus a queue means at most one scoped
/// test runs at a time, in arrival order. (The library's own Serializer is
/// not public in this toolchain, so this is the same idea built from an actor.)
/// Ownership is HANDED to the next waiter rather than dropped: `busy` stays
/// true across the handoff, so a third test can never slip in during the
/// suspension window between one test finishing and the next resuming —
/// the hole a naive `busy = false` + resume implementation leaves.
actor SeamGate {
    static let shared = SeamGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ work: @Sendable () async throws -> Void) async throws {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
            // Resumed = ownership was handed to us; `busy` is true on our behalf.
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        try await work()
    }
}

extension Trait where Self == SeamSerialized {
    static var seamSerialized: SeamSerialized { SeamSerialized() }
}
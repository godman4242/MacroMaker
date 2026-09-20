import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// Wave 7, feature 4 — macro chaining (features.json F-15). A step can run ANOTHER macro by
/// its library id: the player resolves the id at run time, so a macro renamed or re-saved
/// keeps working, and a deleted one surfaces a loud error step instead of a silent skip.
/// Cycles are caught at launch (fail loud, don't launch) and the nesting depth is capped at 3.
@Suite("Macro chaining", .serialized, .seamSerialized)
struct MacroChainingTests {

    // MARK: The step

    /// A run-macro step round-trips through the file (version 2 carries "macro": id).
    @Test func aRunMacroStepRoundTripsThroughTheFile() throws {
        let id = UUID()
        let macro = Macro(name: "Chain", createdAt: Date(timeIntervalSince1970: 1_789_000_000), events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.02, action: .keyUp(0), flags: 0),
            MacroEvent(time: 0.5, action: .runMacro(id), flags: 0),
        ])
        let decoded = try Macro(jsonData: macro.jsonData())
        #expect(decoded.events.last?.action == .runMacro(id))

        // A pinned v2 file decodes the same way.
        let json = """
        { "format": "macromaker", "version": 2, "name": "Pinned", "createdAt": "2026-09-16T10:00:00Z",
          "events": [ { "t": 0, "type": "runMacro", "macro": "\(id.uuidString)", "flags": 0 } ] }
        """
        let pinned = try Macro(jsonData: Data(json.utf8))
        #expect(pinned.events.map(\.action) == [.runMacro(id)])
    }

    /// A run-macro step with a missing/invalid id fails only that step's decode loudly
    /// (DecodingError) — a chained macro without its id is a corrupt step, not a blank one.
    @Test func aRunMacroStepWithoutAnIdThrows() {
        let json = #"""
        { "format": "macromaker", "version": 2, "name": "x", "createdAt": "2026-09-16T10:00:00Z",
          "events": [ { "t": 0, "type": "runMacro" } ] }
        """#
        #expect(throws: DecodingError.self) { try Macro(jsonData: Data(json.utf8)) }
    }

    /// The summary line the table shows.
    @Test @MainActor func theSummaryNamesItARunStep() {
        let id = UUID()
        let event = MacroEvent(time: 0, action: .runMacro(id), flags: 0)
        #expect(event.summary == "Run macro")
    }

    // MARK: Cycle detection + depth cap (pure rules)

    /// The launch guard: a chain that revisits a macro it already ran is refused at launch
    /// with the cycle named; a straight-line chain (A → B → C) passes; depth beyond 3 is
    /// refused with the too-deep name.
    @Test func cycleDetectionRefusesLoopsAtLaunch() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        // Straight line A→B→C: fine.
        let straight: [UUID: [UUID]] = [a: [b], b: [c], c: []]
        #expect(ChainingRules.validate(root: a, childrenByRoot: straight) == nil,
                "a straight-line chain launches")

        // Cycle A→B→A.
        let cycle: [UUID: [UUID]] = [a: [b], b: [a]]
        let verdict = ChainingRules.validate(root: a, childrenByRoot: cycle)
        #expect(verdict?.isCycle == true, "a cycle is refused as a cycle, not a depth error")

        // Depth: A→B→C→D is depth 4 — refused as too deep.
        let deep: [UUID: [UUID]] = [a: [b], b: [c], c: [d], d: []]
        let deepVerdict = ChainingRules.validate(root: a, childrenByRoot: deep)
        #expect(deepVerdict?.isTooDeep == true, "a chain four deep is refused as too deep")
    }

    /// The depth cap counts the run-macro STEP depth: the root is depth 1, so A→B→C is
    /// exactly 3 deep and legal, A→B→C→D is 4 and refused.
    @Test func aSelfReferencingMacroIsACycle() {
        let a = UUID()
        let selfLoop: [UUID: [UUID]] = [a: [a]]
        #expect(ChainingRules.validate(root: a, childrenByRoot: selfLoop)?.isCycle == true)
    }

    // MARK: Playback — resolution and the loud error step

    /// A run-macro step resolves the id AT RUN TIME and plays the referenced macro's events
    /// inline: the child's events land in the posted stream right after the parent's.
    @Test func aRunMacroStepPlaysTheReferencedMacrosEvents() throws {
        final class PostBox: @unchecked Sendable { var events: [CGEventType] = []; let lock = NSLock() }
        let box = PostBox()
        let priorPoster = EventSynthesizer.eventPoster
        EventSynthesizer.eventPoster = { box.lock.lock(); defer { box.lock.unlock() }; box.events.append($0.type) }
        defer { EventSynthesizer.eventPoster = priorPoster }

        let childID = UUID()
        let child = Macro(name: "Child", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .keyDown(CGKeyCode(11), isRepeat: false), flags: 0),
            MacroEvent(time: 0.01, action: .keyUp(CGKeyCode(11)), flags: 0),
        ])
        let parent = Macro(name: "Parent", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .keyDown(CGKeyCode(0), isRepeat: false), flags: 0),
            MacroEvent(time: 0.01, action: .keyUp(CGKeyCode(0)), flags: 0),
            MacroEvent(time: 0.5, action: .runMacro(childID), flags: 0),
        ])

        let resolved: [UUID: Macro] = [childID: child]
        let plan = MacroPlayer.Plan(events: parent.events, repeats: 1, speed: 1,
                                    humanizer: HumanizerSettings(),
                                    chain: ChainedMacros(depthLimit: 3, resolve: { id in resolved[id] }))
        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w7-chain") { worker in
            MacroPlayer.play(plan, worker: worker) { _, _ in }
            done.signal()
        }
        let settled = done.wait(timeout: .now() + 5) == .success
        #expect(settled, "playback must finish on its own")
        guard settled else { return }

        box.lock.lock(); let types = box.events; box.lock.unlock()
        // Parent's key (0) then child's key (11): keyDown posts one event each.
        let downs = types.filter { $0 == .keyDown || $0 == .flagsChanged }
        #expect(downs.count == 2, "both the parent's and the child's key presses replay, got \(types)")
    }

    /// A run-macro step whose id resolves to nothing (the macro was deleted) makes the run
    /// FAIL LOUD: the final report says finished with a failure message, never a silent skip.
    @Test func aMissingReferencedMacroFailsLoudly() {
        let missingID = UUID()
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .runMacro(missingID), flags: 0),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings(),
           chain: ChainedMacros(depthLimit: 3, resolve: { _ in nil }))

        final class ReportBox: @unchecked Sendable {
            var failures: [MacroPlayer.ChainFailure] = []
            var finishedFlags: [Bool] = []
            let lock = NSLock()
        }
        let box = ReportBox()
        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w7-chain-missing") { worker in
            MacroPlayer.play(plan, worker: worker,
                             report: { _, finished in
                                 box.lock.lock(); defer { box.lock.unlock() }
                                 box.finishedFlags.append(finished)
                             },
                             chainFailure: { failure in
                                 box.lock.lock(); defer { box.lock.unlock() }
                                 box.failures.append(failure)
                             })
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)

        box.lock.lock()
        let failures = box.failures
        let finishedFlags = box.finishedFlags
        box.lock.unlock()
        #expect(failures == [MacroPlayer.ChainFailure(stepIndex: 0, macroID: missingID, depth: nil)],
                "the chain failure must name the missing macro at the step that referenced it, got \(failures)")
        #expect(finishedFlags.last == false,
                "the run's final report must NOT claim natural completion, got \(finishedFlags)")
    }

    // MARK: The launch check (fail loud, don't launch)

    /// A macro's run-macro children, in step order — the launch check walks these.
    @Test func aMacrosChildrenAreItsRunMacroStepsInOrder() {
        let a = UUID(), b = UUID()
        let macro = Macro(name: "Root", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.1, action: .runMacro(a), flags: 0),
            MacroEvent(time: 0.2, action: .keyUp(0), flags: 0),
            MacroEvent(time: 0.3, action: .runMacro(b), flags: 0),
        ])
        #expect(ChainingRules.children(of: macro) == [a, b],
                "the children are the run-macro steps in step order")
    }

    /// The launch check resolves each referenced macro (once) and refuses the run with a
    /// message naming the loop; a straight chain and a chain through a DELETED macro both
    /// pass the launch check — the deleted one is a run-time failure, handled loud at play.
    @Test func theLaunchCheckRefusesALoopAndNamesIt() {
        let a = UUID(), b = UUID(), c = UUID()
        let macroA = Macro(name: "Alpha", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(b), flags: 0),
        ])
        let macroB = Macro(name: "Beta", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(a), flags: 0),
        ])
        let root = Macro(name: "Root", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(a), flags: 0),
        ])
        let resolved: [UUID: Macro] = [a: macroA, b: macroB]

        let problem = MacroPlayer.chainProblem(for: root, resolve: { resolved[$0] })
        #expect(problem?.contains("loop") == true,
                "the launch check refuses the loop with a message saying so, got \(problem ?? "nil")")
        #expect(problem?.contains("Alpha") == true || problem?.contains("Beta") == true,
                "the message names a macro in the loop")

        // A straight chain A→B (root excluded from the cap by design: root=1, A=2, B=3) passes.
        let straightRoot = Macro(name: "Straight", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(a), flags: 0),
        ])
        let straightB = Macro(name: "Beta2", createdAt: Date(), events: [])
        let straight: [UUID: Macro] = [a: Macro(name: "Alpha", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(b), flags: 0),
        ]), b: straightB]
        #expect(MacroPlayer.chainProblem(for: straightRoot, resolve: { straight[$0] }) == nil,
                "a chain three deep launches")

        // A step referencing a macro that isn't in the library is NOT a launch failure —
        // the run starts and the missing macro fails loud at the step that references it.
        let dangling = Macro(name: "Dangling", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(c), flags: 0),
        ])
        #expect(MacroPlayer.chainProblem(for: dangling, resolve: { _ in nil }) == nil,
                "a deleted macro is a run-time failure, not a launch refusal")
    }

    /// A chain that nests past the cap is also refused at launch, with the depth named.
    @Test func theLaunchCheckRefusesAChainPastTheDepthCap() {
        let a = UUID(), b = UUID(), c = UUID()
        let macroA = Macro(name: "A", createdAt: Date(), events: [MacroEvent(time: 0, action: .runMacro(b), flags: 0)])
        let macroB = Macro(name: "B", createdAt: Date(), events: [MacroEvent(time: 0, action: .runMacro(c), flags: 0)])
        let macroC = Macro(name: "C", createdAt: Date(), events: [])
        let root = Macro(name: "Root", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .runMacro(a), flags: 0),
        ])
        let resolved: [UUID: Macro] = [a: macroA, b: macroB, c: macroC]
        let problem = MacroPlayer.chainProblem(for: root, resolve: { resolved[$0] })
        #expect(problem?.contains("deep") == true,
                "a chain four deep is refused with a message naming the depth, got \(problem ?? "nil")")
    }

    // MARK: Editing — inserting a run-macro step

    /// The pure rule: a run-macro step lands right after the selected step, slightly later
    /// on the timeline; out-of-range inserts and empty events are refused (no change).
    @Test func insertRunMacroPlacesTheStepAfterTheSelectedOne() {
        let id = UUID()
        let down = MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0)
        let up = MacroEvent(time: 0.5, action: .keyUp(0), flags: 0)
        let events = [down, up]

        let inserted = MacroLibraryRules.insertRunMacro(events: events, atIndex: 0, macroID: id)
        #expect(inserted.count == 3, "one step is inserted, got \(inserted.count)")
        #expect(inserted[1].action == .runMacro(id), "the new step sits right after the selected one")
        #expect(abs(inserted[1].time - 0.02) < 0.001,
                "it plays just after the selected step, got \(inserted[1].time)")
        #expect(inserted.map(\.time).last == 0.5, "later steps keep their times")

        #expect(MacroLibraryRules.insertRunMacro(events: events, atIndex: 2, macroID: id) == events,
                "an out-of-range insert changes nothing")
        #expect(MacroLibraryRules.insertRunMacro(events: [], atIndex: 0, macroID: id) == [],
                "an empty macro can't gain a step this way")
    }

    // MARK: The full toggle path — refuse the loop, keep the UI honest

    /// The launch refusal through the real toggle(): a library whose A→B reference each other
    /// refuses to play A, says why (a loop, named), and never enters a running phase.
    /// A DELETED reference is not a refusal — that run starts and fails loud at the step.
    @MainActor @Test func toggleRefusesACyclicLibraryPairWithAWarning() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mm-chain-\(UUID().uuidString)", directoryHint: .isDirectory)
        MacroLibrary.folderOverride = folder
        let savedIndex = UserDefaults.standard.data(forKey: MacroLibrary.indexKey)
        let model = AppModel.shared
        let player = model.player
        let savedSettings = player.settings
        let savedPoster = EventSynthesizer.eventPoster
        EventSynthesizer.eventPoster = { _ in }
        model.permissions.forceAccessibilityTrusted = true
        func cleanup() {
            EventSynthesizer.eventPoster = savedPoster
            model.permissions.forceAccessibilityTrusted = false
            MacroLibrary.folderOverride = nil
            if let savedIndex { UserDefaults.standard.set(savedIndex, forKey: MacroLibrary.indexKey) }
            else { UserDefaults.standard.removeObject(forKey: MacroLibrary.indexKey) }
            try? FileManager.default.removeItem(at: folder)
        }
        defer { cleanup() }

        let library = MacroLibrary(load: false)
        let macroA = Macro(name: "Alpha", events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.01, action: .keyUp(0), flags: 0),
        ])
        let recordA = try #require(library.add(macroA, named: "Alpha"))
        let recordB = try #require(library.add(
            Macro(name: "Beta", events: [
                MacroEvent(time: 0, action: .runMacro(recordA.id), flags: 0),
            ]), named: "Beta"))
        // Make A reference B after both exist: the loop A→B→A.
        var looped = macroA
        looped.events.append(MacroEvent(time: 0.02, action: .runMacro(recordB.id), flags: 0))
        try #require(library.update(recordA, with: looped) != nil)
        // toggle reads the player's chain library — point it at this suite's records.
        player.chainLibrary = library

        player.toggle(looped, trigger: .hotkey)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.session.phase == .idle, "a cyclic macro must not launch")
        #expect(player.runWarning?.contains("loop") == true,
                "the refusal names the loop, got \(player.runWarning ?? "nil")")

        // A dangling reference launches: the deleted-macro failure is the RUN's loud error.
        let dangling = Macro(name: "Dangling", events: [
            MacroEvent(time: 0, action: .runMacro(UUID()), flags: 0),
        ])
        player.toggle(dangling, trigger: .hotkey)
        #expect(player.session.phase == .running,
                "a deleted reference is a run-time failure, not a launch refusal")
        model.stopAll()
        player.settings = savedSettings
        cleanup()
    }
}
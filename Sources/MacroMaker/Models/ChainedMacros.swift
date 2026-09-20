import Foundation

/// Chained macros (feature 4): the launch-time cycle check and the run-time resolution
/// contract for `runMacro` steps.
///
/// All pure rules, testable without a library or a run:
/// - `validate` walks the chain from the root and refuses it — named — when a macro
///   revisits one already on the current path (a cycle) or nests deeper than the cap
///   (a chain four deep is a runaway, not a feature).
/// - The plan-side value carries the resolver the player calls AT RUN TIME, so a macro
///   renamed or re-saved since launch still resolves, and one deleted since launch
///   surfaces a loud failure instead of a silent skip.
enum ChainingVerdict: Equatable, Sendable {
    case cycle(UUID)
    case tooDeep(UUID)

    var isCycle: Bool { if case .cycle = self { return true }; return false }
    var isTooDeep: Bool { if case .tooDeep = self { return true }; return false }
}

enum ChainingRules {
    /// The nesting cap: root = 1, so A→B→C is exactly 3 and A→B→C→D is refused.
    static let defaultDepthLimit = 3

    /// A macro's run-macro children, in step order — the launch check and the depth
    /// accounting both walk these, one per `runMacro` step.
    static func children(of macro: Macro) -> [UUID] {
        macro.events.compactMap { event in
            if case let .runMacro(id) = event.action { return id }
            return nil
        }
    }

    /// Refuses the chain before it launches: nil = safe to run. `childrenByRoot` maps a
    /// macro id to its run-macro children (empty for a plain macro); the walk is
    /// depth-first from `root`, tracking the current path for cycles.
    static func validate(root: UUID, childrenByRoot: [UUID: [UUID]],
                         depthLimit: Int = defaultDepthLimit) -> ChainingVerdict? {
        var path: Set<UUID> = []

        func walk(_ id: UUID, _ depth: Int) -> ChainingVerdict? {
            if path.contains(id) { return .cycle(id) }
            guard depth <= depthLimit else { return .tooDeep(id) }
            path.insert(id)
            defer { path.remove(id) }
            for child in childrenByRoot[id] ?? [] {
                if let verdict = walk(child, depth + 1) { return verdict }
            }
            return nil
        }

        return walk(root, 1)
    }
}

/// The plan-side value: what the player needs to resolve and expand a chain at run time.
/// `resolve` is called on the worker thread, once per run-macro step, AT RUN TIME.
struct ChainedMacros: Sendable {
    typealias Resolver = @Sendable (UUID) -> Macro?

    let depthLimit: Int
    let resolve: Resolver

    init(depthLimit: Int = ChainingRules.defaultDepthLimit, resolve: @escaping Resolver) {
        self.depthLimit = depthLimit
        self.resolve = resolve
    }
}
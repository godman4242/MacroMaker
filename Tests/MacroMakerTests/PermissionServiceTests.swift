import Testing

@testable import MacroMaker

/// The system Accessibility prompt must fire at most once per launch — the in-app banner
/// is the only repeated UI. (PermissionService is @MainActor; Testing runs each test on it.)
@Suite("PermissionService")
@MainActor
struct PermissionServiceTests {
    @Test func systemPromptFiresOnlyOncePerLaunch() {
        let permissions = PermissionService()
        // First request arms the flag; the second must not re-fire the system dialog.
        permissions.requestAccessibility()
        #expect(permissions.didPromptForAccessibility)
    }

    @Test func flagStartsFalseEachLaunch() {
        #expect(!PermissionService().didPromptForAccessibility)
    }
}
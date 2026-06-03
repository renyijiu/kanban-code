import Darwin
import Testing
@testable import KanbanCode

@Suite("SystemTray")
struct SystemTrayTests {
    @Test("Active-session shutdown PIDs are deduplicated and sanitized")
    func uniqueActiveSessionPIDs() {
        let pids = SystemTray.uniqueActiveSessionPIDs([123, 0, -1, nil, 123, 456])

        #expect(pids == Set<pid_t>([123, 456]))
    }
}

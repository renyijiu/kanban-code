import SwiftUI
import KanbanCodeCore

struct QuitConfirmationSession: Identifiable {
    let session: TmuxSession
    let cardTitle: String?

    var id: String { session.name }
}

struct QuitConfirmationView: View {
    let sessions: [QuitConfirmationSession]
    let onCancel: () -> Void
    let onQuit: (Bool) -> Void

    @State private var killManagedSessions: Bool

    init(
        sessions: [QuitConfirmationSession],
        killManagedSessions: Bool,
        onCancel: @escaping () -> Void,
        onQuit: @escaping (Bool) -> Void
    ) {
        self.sessions = sessions
        self.onCancel = onCancel
        self.onQuit = onQuit
        _killManagedSessions = State(initialValue: killManagedSessions)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.app(.largeTitle))
                    .foregroundStyle(.secondary)
                Text("Quit Kanban?")
                    .font(.app(.headline))
                Text("You have \(sessions.count) managed tmux session\(sessions.count == 1 ? "" : "s") running.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Table(sessions) {
                TableColumn("") { row in
                    Circle()
                        .fill(row.session.attached ? .green : .gray)
                        .frame(width: 8, height: 8)
                }
                .width(16)

                TableColumn("Session") { row in
                    Text(row.session.name)
                        .lineLimit(1)
                }

                TableColumn("Card") { row in
                    if let cardTitle = row.cardTitle {
                        Text(cardTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("Path") { row in
                    Text(abbreviateHomePath(row.session.path))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Toggle("Kill managed sessions on quit", isOn: $killManagedSessions)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Quit Kanban") {
                    onQuit(killManagedSessions)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

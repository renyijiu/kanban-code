import AppKit
import SwiftUI
import KanbanCodeCore

enum CodexSessionDestination: Equatable {
    case codexThread(URL)
    case tmux(String)
    case details
}

enum CodexSessionNavigation {
    static func destination(
        executionBinding: CodexExecutionBinding?,
        legacyTmuxSessionName: String?
    ) -> CodexSessionDestination {
        if let threadId = executionBinding?.threadId,
           let url = codexThreadURL(threadId: threadId) {
            return .codexThread(url)
        }

        if let tmuxName = executionBinding?.tmuxSessionName ?? legacyTmuxSessionName {
            return .tmux(tmuxName)
        }

        return .details
    }

    static func codexThreadURL(threadId: String) -> URL? {
        guard !threadId.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encodedThreadId = threadId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.percentEncodedPath = "/\(encodedThreadId)"
        return components.url
    }
}

extension CodexRuntimeBackend {
    var boardLabel: String {
        switch self {
        case .app: "Codex App"
        case .cliTmux: "CLI + tmux"
        case .unknown: "Unknown runtime"
        }
    }

    var shortBoardLabel: String {
        switch self {
        case .app: "App"
        case .cliTmux: "CLI"
        case .unknown: "Unknown"
        }
    }

    var boardSymbol: String {
        switch self {
        case .app: "macwindow"
        case .cliTmux: "terminal"
        case .unknown: "questionmark.circle"
        }
    }
}

extension TelemetryQuality {
    var boardLabel: String {
        switch self {
        case .precise: "Precise telemetry"
        case .limited: "Limited telemetry"
        case .unknown: "Unknown telemetry"
        }
    }

    var boardSymbol: String {
        switch self {
        case .precise: "waveform.path.ecg"
        case .limited: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }

    var boardColor: Color {
        switch self {
        case .precise: .green
        case .limited: .orange
        case .unknown: .secondary
        }
    }
}

extension LifecycleWaitReason {
    var attentionLabel: String {
        switch self {
        case .input: "Needs input"
        case .approval: "Needs approval"
        case .ordinaryStop: "Stopped"
        case .fault: "Failed"
        case .disconnected: "Disconnected"
        case .launchUncertain: "Launch uncertain"
        case .unknown: "Needs attention"
        }
    }

    var attentionSymbol: String {
        switch self {
        case .input: "text.bubble"
        case .approval: "hand.raised"
        case .ordinaryStop: "pause.circle"
        case .fault: "exclamationmark.octagon"
        case .disconnected: "wifi.slash"
        case .launchUncertain: "arrow.clockwise.circle"
        case .unknown: "exclamationmark.circle"
        }
    }
}

extension AttentionPrimaryAction {
    var buttonLabel: String {
        switch self {
        case .respond: "Respond"
        case .approve: "Review"
        case .retry: "Inspect"
        case .inspect: "Inspect"
        }
    }
}

struct RuntimeTelemetryBadge: View {
    let executionBinding: CodexExecutionBinding?

    private var runtime: CodexRuntimeBackend {
        executionBinding?.backend ?? .unknown
    }

    private var telemetry: TelemetryQuality {
        executionBinding?.telemetryQuality ?? .unknown
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: runtime.boardSymbol)
            Text(runtime.shortBoardLabel)
            Image(systemName: telemetry.boardSymbol)
                .foregroundStyle(telemetry.boardColor)
        }
        .font(.app(.caption2, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .help("\(runtime.boardLabel) · \(telemetry.boardLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runtime")
        .accessibilityValue("\(runtime.boardLabel), \(telemetry.boardLabel)")
    }
}

struct CodexBoardHeader: View {
    let runtime: CodexRuntimeBackend
    let boardCount: Int
    let allSessionsCount: Int
    let onSelectRuntime: (CodexRuntimeBackend) -> Void
    let onShowAllSessions: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Codex runtime", selection: Binding(
                get: { runtime },
                set: { runtime in onSelectRuntime(runtime) }
            )) {
                Label("Codex App", systemImage: CodexRuntimeBackend.app.boardSymbol)
                    .tag(CodexRuntimeBackend.app)
                Label("CLI + tmux", systemImage: CodexRuntimeBackend.cliTmux.boardSymbol)
                    .tag(CodexRuntimeBackend.cliTmux)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .accessibilityLabel("Board runtime")
            .accessibilityValue(runtime.boardLabel)
            .help("Switching changes the five visible lanes; queued work in the other runtime stays paused")

            Text("\(boardCount) in this runtime")
                .font(.app(.caption))
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onShowAllSessions) {
                Label("All Sessions", systemImage: "tray.full")
                Text("\(allSessionsCount)")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .help("Search sessions from every runtime, including legacy sessions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct AttentionStrip: View {
    let items: [AttentionItem]
    let onPrimaryAction: (AttentionItem) -> Void
    let onOpenSession: (AttentionItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(.orange)
                    Text("Needs your attention")
                        .font(.app(.headline))
                    Text("\(items.count)")
                        .font(.app(.caption, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.16), in: Capsule())
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: items.count > 3) {
                    LazyHStack(spacing: 8) {
                        ForEach(items) { item in
                            AttentionItemView(
                                item: item,
                                onPrimaryAction: { onPrimaryAction(item) },
                                onOpenSession: { onOpenSession(item) }
                            )
                        }
                    }
                }
                .frame(height: 70)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.055))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(items.count) sessions need attention")
        }
    }
}

private struct AttentionItemView: View {
    let item: AttentionItem
    let onPrimaryAction: () -> Void
    let onOpenSession: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.reason.attentionSymbol)
                .foregroundStyle(item.reason == .fault ? .red : .orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.app(.subheadline, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.reason.attentionLabel)
                    Text("·")
                    Text(item.runtime.shortBoardLabel)
                    if let project = item.project {
                        Text("·")
                        Text(project)
                    }
                    Text("·")
                    Text(item.age.formattedAttentionAge)
                }
                .font(.app(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Button(item.primaryAction.buttonLabel, action: onPrimaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onOpenSession) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open original session")
            .disabled(!item.canOpenSession)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.18)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.reason.attentionLabel), \(item.runtime.boardLabel)")
        .accessibilityAction(named: item.primaryAction.buttonLabel, onPrimaryAction)
        .accessibilityAction(named: "Open original session", onOpenSession)
    }
}

private extension TimeInterval {
    var formattedAttentionAge: String {
        if self < 60 { return "now" }
        if self < 3_600 { return "\(Int(self / 60))m" }
        if self < 86_400 { return "\(Int(self / 3_600))h" }
        return "\(Int(self / 86_400))d"
    }
}

struct CodexReviewFeedbackDialog: View {
    let title: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Void
    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue (title)")
                .font(.title2.bold())
            Text("Feedback is sent to the original Codex session. The card returns to In Progress only after Codex acknowledges it.")
                .foregroundStyle(.secondary)
            TextEditor(text: $feedback)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Send Feedback") { onSubmit(feedback) }
                    .buttonStyle(.borderedProminent)
                    .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct CodexPendingActionDialog: View {
    let action: CodexPendingAction
    let onCancel: () -> Void
    let onRespond: (Bool?, String?) -> Void
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title)
                .font(.title2.bold())
            ScrollView {
                Text(action.details)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            if action.kind == .input {
                TextEditor(text: $input)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                if action.kind == .approval {
                    Button("Deny") { onRespond(false, nil) }
                    Button("Approve") { onRespond(true, nil) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Send") { onRespond(nil, input) }
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct AllSessionsView: View {
    let cards: [KanbanCodeCard]
    let onOpen: (String) -> Void
    let onDismiss: () -> Void
    @State private var query = ""

    private var filteredCards: [KanbanCodeCard] {
        let sorted = cards.sorted {
            ($0.link.lastActivity ?? $0.link.updatedAt) > ($1.link.lastActivity ?? $1.link.updatedAt)
        }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return sorted }
        return sorted.filter { card in
            card.displayTitle.localizedCaseInsensitiveContains(normalized)
                || (card.projectName?.localizedCaseInsensitiveContains(normalized) ?? false)
                || (card.link.sessionLink?.sessionId.localizedCaseInsensitiveContains(normalized) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All Sessions")
                    .font(.app(.title2, weight: .semibold))
                Text("\(cards.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            TextField("Search title, project, or session ID", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            Divider()

            if cards.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "tray",
                    description: Text("Created and discovered sessions will appear here across both runtimes.")
                )
            } else if filteredCards.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(filteredCards, id: \.id) { card in
                        Button {
                            onOpen(card.id)
                        } label: {
                            HStack(spacing: 10) {
                                AssistantIcon(assistant: card.link.effectiveAssistant)
                                    .frame(width: 16, height: 16)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.displayTitle)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(card.column.displayName)
                                        if let projectName = card.projectName {
                                            Text("·")
                                            Text(projectName)
                                        }
                                        Text("·")
                                        Text(card.relativeTime)
                                    }
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if card.link.effectiveAssistant == .codex {
                                    RuntimeTelemetryBadge(executionBinding: card.link.executionBinding)
                                } else {
                                    Text("Legacy")
                                        .font(.app(.caption2, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open Original Session") { onOpen(card.id) }
                        }
                        .accessibilityLabel("\(card.displayTitle), \(card.column.displayName)")
                        .accessibilityHint("Opens the original runtime session or card details")
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

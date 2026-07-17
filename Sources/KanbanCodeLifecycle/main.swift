import Foundation
import KanbanCodeCore

@main
enum KanbanCodeLifecycleCommand {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CodexLifecycleInboxError.invalidEnvelope("expected review-ready or hook-event")
            }
            let command = CommandLine.arguments[1]
            let input: Data
            if command == "hook-event" {
                input = try readBoundedStandardInput()
            } else {
                input = Data()
            }
            _ = try await CodexLifecycleHelper.emit(command: command, standardInput: input)
        } catch {
            // Never print event contents or the per-attempt capability.
            FileHandle.standardError.write(Data("kanban-code-lifecycle: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func readBoundedStandardInput() throws -> Data {
        let maximum = CodexLifecycleInboxWriter.maximumEventBytes
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(64 * 1024, maximum + 1 - input.count)),
              !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= maximum else {
                throw CodexLifecycleInboxError.eventTooLarge(actual: input.count, maximum: maximum)
            }
        }
        return input
    }
}

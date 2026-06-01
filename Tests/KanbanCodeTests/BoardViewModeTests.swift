import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Board View Mode")
struct BoardViewModeTests {
    @Test("View mode raw values stay stable for persistence")
    func rawValues() {
        #expect(BoardViewMode.kanban.rawValue == "kanban")
        #expect(BoardViewMode.list.rawValue == "list")
    }

    @Test("List sections keep column order and include empty columns")
    func listSectionsPreserveOrder() {
        let backlog = KanbanCodeCard(link: Link(id: "card_backlog", column: .backlog, updatedAt: .now))
        let waiting = KanbanCodeCard(link: Link(id: "card_waiting", column: .waiting, updatedAt: .now))

        let sections = ListBoardSection.make(
            columns: [.backlog, .inProgress, .waiting, .done],
            cardsInColumn: { column in
                switch column {
                case .backlog: [backlog]
                case .waiting: [waiting]
                default: []
                }
            }
        )

        #expect(sections.count == 4)
        #expect(sections[0].column == .backlog)
        #expect(sections[0].cards.map(\.id) == ["card_backlog"])
        #expect(sections[1].column == .inProgress)
        #expect(sections[1].cards.isEmpty)
        #expect(sections[2].column == .waiting)
        #expect(sections[2].cards.map(\.id) == ["card_waiting"])
        #expect(sections[3].column == .done)
        #expect(sections[3].cards.isEmpty)
    }

    @Test("Collapsed list sections round-trip through storage")
    func collapsedSectionsRoundTrip() {
        let encoded = ListSectionCollapseState.encode([.inReview, .waiting])
        let decoded = ListSectionCollapseState.decode(encoded)

        #expect(decoded == [.inReview, .waiting])
    }

    @Test("Collapsed list sections ignore empty persisted state")
    func collapsedSectionsEmptyState() {
        #expect(ListSectionCollapseState.encode([]) == "")
        #expect(ListSectionCollapseState.decode("") == [])
    }

    @Test("Pinned and lane rows use distinct SwiftUI identities")
    func pinnedAndLaneRowsUseDistinctIdentities() {
        let cardId = "card_pin1"

        #expect(ListBoardRowIdentity.pinned(cardId) != .column(.waiting, cardId))
        #expect(ListBoardRowIdentity.column(.waiting, cardId) != .column(.inProgress, cardId))
    }
}

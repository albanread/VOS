import Foundation

struct ABCJingleTimelineItem: Identifiable, Codable, Hashable {
    var id: UUID
    var jingleCardID: UUID
    var afterParagraphID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        jingleCardID: UUID,
        afterParagraphID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jingleCardID = jingleCardID
        self.afterParagraphID = afterParagraphID
        self.createdAt = createdAt
    }
}

struct ABCJingleTimelineStore: Codable {
    var items: [ABCJingleTimelineItem]

    static let `default` = ABCJingleTimelineStore(items: [])
}
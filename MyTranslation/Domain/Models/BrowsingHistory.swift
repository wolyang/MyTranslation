import Foundation

struct BrowsingHistory: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    var title: String
    var visitedAt: Date

    init(id: UUID = UUID(), url: String, title: String, visitedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

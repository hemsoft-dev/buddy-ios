import Foundation
import SwiftData

@Model
final class DashboardSnapshot {
    @Attribute(.unique) var id: String
    var serviceID: String
    var payload: Data
    var refreshedAt: Date

    init(id: String, serviceID: String, payload: Data, refreshedAt: Date = .now) {
        self.id = id
        self.serviceID = serviceID
        self.payload = payload
        self.refreshedAt = refreshedAt
    }
}

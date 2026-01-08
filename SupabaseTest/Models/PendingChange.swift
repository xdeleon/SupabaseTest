import Foundation
import SwiftData

/// Represents a pending change that needs to be synced to Supabase
@Model
final class PendingChange {
    var id: UUID
    var entityType: String  // "class" or "student"
    var entityId: UUID
    var operationType: String  // "insert", "update", "delete"
    var payload: Data  // JSON encoded data for insert/update
    var createdAt: Date
    var retryCount: Int

    init(
        entityType: String,
        entityId: UUID,
        operationType: String,
        payload: Data = Data(),
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.entityType = entityType
        self.entityId = entityId
        self.operationType = operationType
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = 0
    }
}

// MARK: - Payload Types

struct ClassPayload: Codable {
    let id: UUID
    let name: String
    let notes: String
    let userId: UUID
}

struct StudentPayload: Codable {
    let id: UUID
    let name: String
    let notes: String
    let classId: UUID
    let userId: UUID
}

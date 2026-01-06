import Foundation
import SwiftData

@Model
final class SchoolClass {
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Student.schoolClass)
    var students: [Student] = []

    init(
        id: UUID = UUID(),
        name: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SchoolClass {
    /// Convert to dictionary for Supabase
    var supabaseData: [String: Any] {
        [
            "id": id.uuidString,
            "class_name": name,
            "notes": notes,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt)
        ]
    }
}

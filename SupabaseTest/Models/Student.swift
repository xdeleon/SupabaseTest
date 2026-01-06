import Foundation
import SwiftData

@Model
final class Student {
    var id: UUID
    var name: String
    var notes: String
    var classId: UUID
    var createdAt: Date
    var updatedAt: Date

    var schoolClass: SchoolClass?

    init(
        id: UUID = UUID(),
        name: String = "",
        notes: String = "",
        classId: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.classId = classId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Student {
    /// Convert to dictionary for Supabase
    var supabaseData: [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "notes": notes,
            "class_id": classId.uuidString,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt)
        ]
    }
}

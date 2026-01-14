import Foundation
import SwiftData

@Model
final class SchoolClass {
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Student.schoolClass)
    var students: [Student] = []

    init(
        id: UUID = UUID(),
        name: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

extension SchoolClass {
    var activeStudents: [Student] {
        students.filter { $0.deletedAt == nil }
    }

    /// Convert to dictionary for Supabase
    var supabaseData: [String: Any] {
        var data: [String: Any] = [
            "id": id.uuidString,
            "class_name": name,
            "notes": notes,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt)
        ]
        if let deletedAt {
            data["deleted_at"] = ISO8601DateFormatter().string(from: deletedAt)
        }
        return data
    }
}

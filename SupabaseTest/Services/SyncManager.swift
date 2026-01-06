import Foundation
import SwiftData
import Supabase
import Realtime
import Combine

@MainActor
final class SyncManager: ObservableObject {
    private var modelContext: ModelContext?
    private var realtimeChannel: RealtimeChannelV2?
    private var currentUserId: UUID?

    @Published var isSyncing = false
    @Published var lastSyncError: String?
    @Published var lastUpdate = Date()  // Triggers UI refresh

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Supabase sends dates with fractional seconds, need custom formatter
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try with fractional seconds first
            if let date = formatter.date(from: dateString) {
                return date
            }

            // Fallback to without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
    }()

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Realtime Subscriptions

    func startRealtimeSync() async {
        guard let userId = try? await supabase.auth.session.user.id else {
            print("[Realtime] No user session, skipping realtime sync")
            return
        }

        self.currentUserId = userId
        print("[Realtime] Starting realtime sync for user: \(userId)")

        // Create a single channel for all database changes
        let channel = supabase.realtimeV2.channel("db-changes")
        self.realtimeChannel = channel

        // Listen for class changes (no filter - we filter client-side for reliability)
        let classChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "classes")
        let studentChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "students")

        // Start listening tasks BEFORE subscribing
        Task {
            for await change in classChanges {
                await handleClassChange(change, userId: userId)
            }
        }

        Task {
            for await change in studentChanges {
                await handleStudentChange(change, userId: userId)
            }
        }

        // Subscribe to the channel and monitor status
        await channel.subscribe()

        // Monitor channel status
        Task {
            for await status in channel.statusChange {
                print("[Realtime] Channel status changed: \(status)")
            }
        }

        print("[Realtime] Channel subscribed, status: \(channel.status)")
    }

    func stopRealtimeSync() async {
        await realtimeChannel?.unsubscribe()
        realtimeChannel = nil
        print("[Realtime] Channel unsubscribed")
    }

    // MARK: - Handle Realtime Changes

    private func handleClassChange(_ change: AnyAction, userId: UUID) async {
        guard let context = modelContext else { return }

        do {
            switch change {
            case .insert(let action):
                print("[Realtime] Class INSERT event received")
                let record = try action.decodeRecord(as: ClassRecord.self, decoder: decoder)
                print("[Realtime] Class INSERT decoded: \(record.name), userId: \(record.userId), currentUser: \(userId)")
                // Filter client-side: only process changes for this user
                guard record.userId == userId else {
                    print("[Realtime] Class INSERT skipped - different user")
                    return
                }
                print("[Realtime] Class INSERT processing: \(record.name)")
                await insertClassLocally(record, context: context)

            case .update(let action):
                let record = try action.decodeRecord(as: ClassRecord.self, decoder: decoder)
                guard record.userId == userId else { return }
                print("[Realtime] Class UPDATE: \(record.name)")
                await updateClassLocally(record, context: context)

            case .delete(let action):
                struct DeletePayload: Decodable {
                    let id: UUID
                }
                let payload = try action.decodeOldRecord(as: DeletePayload.self, decoder: decoder)
                print("[Realtime] Class DELETE: \(payload.id)")
                // No user filter needed - if it exists locally, it belongs to this user
                await deleteClassLocally(payload.id, context: context)
            }
        } catch {
            print("[Realtime] Error handling class change: \(error)")
            lastSyncError = "Failed to handle class change: \(error.localizedDescription)"
        }
    }

    private func handleStudentChange(_ change: AnyAction, userId: UUID) async {
        guard let context = modelContext else { return }

        do {
            switch change {
            case .insert(let action):
                let record = try action.decodeRecord(as: StudentRecord.self, decoder: decoder)
                guard record.userId == userId else { return }
                print("[Realtime] Student INSERT: \(record.name)")
                await insertStudentLocally(record, context: context)

            case .update(let action):
                let record = try action.decodeRecord(as: StudentRecord.self, decoder: decoder)
                guard record.userId == userId else { return }
                print("[Realtime] Student UPDATE: \(record.name)")
                await updateStudentLocally(record, context: context)

            case .delete(let action):
                struct DeletePayload: Decodable {
                    let id: UUID
                }
                let payload = try action.decodeOldRecord(as: DeletePayload.self, decoder: decoder)
                print("[Realtime] Student DELETE: \(payload.id)")
                // No user filter needed - if it exists locally, it belongs to this user
                await deleteStudentLocally(payload.id, context: context)
            }
        } catch {
            print("[Realtime] Error handling student change: \(error)")
            lastSyncError = "Failed to handle student change: \(error.localizedDescription)"
        }
    }

    // MARK: - Local Database Operations

    private func insertClassLocally(_ record: ClassRecord, context: ModelContext) async {
        let recordId = record.id
        let existingFetch = FetchDescriptor<SchoolClass>(
            predicate: #Predicate { $0.id == recordId }
        )

        do {
            let existing = try context.fetch(existingFetch)
            print("[Realtime] insertClassLocally: checking if \(record.name) exists, found: \(existing.count)")
            if existing.isEmpty {
                let newClass = SchoolClass(
                    id: record.id,
                    name: record.name,
                    notes: record.notes,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )
                context.insert(newClass)
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Inserted class locally: \(record.name)")
            } else {
                print("[Realtime] Class already exists locally, skipping: \(record.name)")
            }
        } catch {
            print("[Realtime] Error inserting class: \(error)")
        }
    }

    private func updateClassLocally(_ record: ClassRecord, context: ModelContext) async {
        let recordId = record.id
        let fetchDescriptor = FetchDescriptor<SchoolClass>(
            predicate: #Predicate { $0.id == recordId }
        )

        do {
            if let existingClass = try context.fetch(fetchDescriptor).first {
                existingClass.name = record.name
                existingClass.notes = record.notes
                existingClass.updatedAt = record.updatedAt
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Updated class locally: \(record.name)")
            }
        } catch {
            print("[Realtime] Error updating class: \(error)")
        }
    }

    private func deleteClassLocally(_ id: UUID, context: ModelContext) async {
        let fetchDescriptor = FetchDescriptor<SchoolClass>(
            predicate: #Predicate { $0.id == id }
        )

        do {
            if let existingClass = try context.fetch(fetchDescriptor).first {
                context.delete(existingClass)
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Deleted class locally: \(id)")
            }
        } catch {
            print("[Realtime] Error deleting class: \(error)")
        }
    }

    private func insertStudentLocally(_ record: StudentRecord, context: ModelContext) async {
        let recordId = record.id
        let existingFetch = FetchDescriptor<Student>(
            predicate: #Predicate { $0.id == recordId }
        )

        do {
            let existing = try context.fetch(existingFetch)
            if existing.isEmpty {
                let newStudent = Student(
                    id: record.id,
                    name: record.name,
                    notes: record.notes,
                    classId: record.classId,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt
                )

                // Link to class
                let classId = record.classId
                let classFetch = FetchDescriptor<SchoolClass>(
                    predicate: #Predicate { $0.id == classId }
                )
                if let schoolClass = try context.fetch(classFetch).first {
                    newStudent.schoolClass = schoolClass
                }

                context.insert(newStudent)
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Inserted student locally: \(record.name)")
            }
        } catch {
            print("[Realtime] Error inserting student: \(error)")
        }
    }

    private func updateStudentLocally(_ record: StudentRecord, context: ModelContext) async {
        let recordId = record.id
        let fetchDescriptor = FetchDescriptor<Student>(
            predicate: #Predicate { $0.id == recordId }
        )

        do {
            if let existingStudent = try context.fetch(fetchDescriptor).first {
                existingStudent.name = record.name
                existingStudent.notes = record.notes
                existingStudent.updatedAt = record.updatedAt
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Updated student locally: \(record.name)")
            }
        } catch {
            print("[Realtime] Error updating student: \(error)")
        }
    }

    private func deleteStudentLocally(_ id: UUID, context: ModelContext) async {
        let fetchDescriptor = FetchDescriptor<Student>(
            predicate: #Predicate { $0.id == id }
        )

        do {
            if let existingStudent = try context.fetch(fetchDescriptor).first {
                context.delete(existingStudent)
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Deleted student locally: \(id)")
            }
        } catch {
            print("[Realtime] Error deleting student: \(error)")
        }
    }

    // MARK: - Initial Sync

    func performInitialSync() async {
        guard let context = modelContext else { return }
        isSyncing = true

        do {
            let userId = try await supabase.auth.session.user.id

            // Fetch classes from Supabase
            let classRecords: [ClassRecord] = try await supabase
                .from("classes")
                .select()
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            // Sync classes
            for record in classRecords {
                let recordId = record.id
                let fetchDescriptor = FetchDescriptor<SchoolClass>(
                    predicate: #Predicate { $0.id == recordId }
                )
                let existing = try context.fetch(fetchDescriptor)

                if let existingClass = existing.first {
                    // Update if remote is newer
                    if record.updatedAt > existingClass.updatedAt {
                        existingClass.name = record.name
                        existingClass.notes = record.notes
                        existingClass.updatedAt = record.updatedAt
                    }
                } else {
                    // Insert new
                    let newClass = SchoolClass(
                        id: record.id,
                        name: record.name,
                        notes: record.notes,
                        createdAt: record.createdAt,
                        updatedAt: record.updatedAt
                    )
                    context.insert(newClass)
                }
            }

            // Fetch students from Supabase
            let studentRecords: [StudentRecord] = try await supabase
                .from("students")
                .select()
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            // Sync students
            for record in studentRecords {
                let recordId = record.id
                let fetchDescriptor = FetchDescriptor<Student>(
                    predicate: #Predicate { $0.id == recordId }
                )
                let existing = try context.fetch(fetchDescriptor)

                if let existingStudent = existing.first {
                    // Update if remote is newer
                    if record.updatedAt > existingStudent.updatedAt {
                        existingStudent.name = record.name
                        existingStudent.notes = record.notes
                        existingStudent.updatedAt = record.updatedAt
                    }
                } else {
                    // Insert new
                    let newStudent = Student(
                        id: record.id,
                        name: record.name,
                        notes: record.notes,
                        classId: record.classId,
                        createdAt: record.createdAt,
                        updatedAt: record.updatedAt
                    )

                    // Link to class
                    let classId = record.classId
                    let classFetch = FetchDescriptor<SchoolClass>(
                        predicate: #Predicate { $0.id == classId }
                    )
                    if let schoolClass = try context.fetch(classFetch).first {
                        newStudent.schoolClass = schoolClass
                    }

                    context.insert(newStudent)
                }
            }

            try context.save()
        } catch {
            lastSyncError = "Initial sync failed: \(error.localizedDescription)"
        }

        isSyncing = false
    }

    // MARK: - CRUD Operations (with Supabase sync)

    func createClass(name: String, notes: String) async throws -> SchoolClass {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await supabase.auth.session.user.id
        let newClass = SchoolClass(name: name, notes: notes)

        // Insert into Supabase first
        try await supabase
            .from("classes")
            .insert([
                "id": newClass.id.uuidString,
                "class_name": newClass.name,
                "notes": newClass.notes,
                "user_id": userId.uuidString
            ])
            .execute()

        // Then insert locally
        context.insert(newClass)
        try context.save()

        return newClass
    }

    func updateClass(_ schoolClass: SchoolClass) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        schoolClass.updatedAt = Date()

        // Update in Supabase
        try await supabase
            .from("classes")
            .update([
                "class_name": schoolClass.name,
                "notes": schoolClass.notes
            ])
            .eq("id", value: schoolClass.id.uuidString)
            .execute()

        // Save locally
        try context.save()
    }

    func deleteClass(_ schoolClass: SchoolClass) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        // Delete from Supabase (cascade will delete students)
        try await supabase
            .from("classes")
            .delete()
            .eq("id", value: schoolClass.id.uuidString)
            .execute()

        // Delete locally
        context.delete(schoolClass)
        try context.save()
    }

    func createStudent(name: String, notes: String, in schoolClass: SchoolClass) async throws -> Student {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await supabase.auth.session.user.id
        let newStudent = Student(name: name, notes: notes, classId: schoolClass.id)
        newStudent.schoolClass = schoolClass

        // Insert into Supabase first
        try await supabase
            .from("students")
            .insert([
                "id": newStudent.id.uuidString,
                "name": newStudent.name,
                "notes": newStudent.notes,
                "class_id": schoolClass.id.uuidString,
                "user_id": userId.uuidString
            ])
            .execute()

        // Then insert locally
        context.insert(newStudent)
        try context.save()

        return newStudent
    }

    func updateStudent(_ student: Student) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        student.updatedAt = Date()

        // Update in Supabase
        try await supabase
            .from("students")
            .update([
                "name": student.name,
                "notes": student.notes
            ])
            .eq("id", value: student.id.uuidString)
            .execute()

        // Save locally
        try context.save()
    }

    func deleteStudent(_ student: Student) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        // Delete from Supabase
        try await supabase
            .from("students")
            .delete()
            .eq("id", value: student.id.uuidString)
            .execute()

        // Delete locally
        context.delete(student)
        try context.save()
    }
}

// MARK: - Supabase Record Types

struct ClassRecord: Codable {
    let id: UUID
    let name: String
    let notes: String
    let userId: UUID
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name = "class_name"
        case notes
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct StudentRecord: Codable {
    let id: UUID
    let name: String
    let notes: String
    let classId: UUID
    let userId: UUID
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case notes
        case classId = "class_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case noContext
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .noContext:
            return "No model context available"
        case .syncFailed(let message):
            return "Sync failed: \(message)"
        }
    }
}

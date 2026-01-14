import Foundation
import SwiftData
import Supabase
import Realtime
import Combine

@MainActor
final class SyncManager: ObservableObject {
    typealias UserIdProvider = @MainActor () async throws -> UUID
    typealias PendingChangeApplier = @MainActor (PendingChange, UUID) async throws -> Void

    private var modelContext: ModelContext?
    private var realtimeChannel: RealtimeChannelV2?
    private var currentUserId: UUID?
    private let networkMonitor: NetworkMonitoring
    private let userIdProvider: UserIdProvider
    private let pendingChangeApplier: PendingChangeApplier
    private var isProcessingQueue = false
    private var syncEpoch = UUID()

    @Published var isSyncing = false
    @Published var lastSyncError: String?
    @Published var lastUpdate = Date()  // Triggers UI refresh

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(SyncManager.decodeSupabaseDate)
        return decoder
    }()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private nonisolated static func decodeSupabaseDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)

        // Supabase sends dates with fractional seconds; try that first.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            return date
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
    }

    private enum EntityType: String {
        case schoolClass = "class"
        case student = "student"
    }

    private enum OperationType: String {
        case insert
        case update
        case delete
    }

    init(
        networkMonitor: NetworkMonitoring,
        userIdProvider: @escaping UserIdProvider,
        pendingChangeApplier: @escaping PendingChangeApplier
    ) {
        self.networkMonitor = networkMonitor
        self.userIdProvider = userIdProvider
        self.pendingChangeApplier = pendingChangeApplier
        networkMonitor.setConnectivityRestoredHandler { [weak self] in
            guard let self = self else { return }
            await self.handleConnectivityRestored()
        }
    }

    convenience init() {
        self.init(
            networkMonitor: NetworkMonitor(),
            userIdProvider: { try await supabase.auth.session.user.id },
            pendingChangeApplier: SyncManager.defaultPendingChangeApplier
        )
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Connectivity

    private func handleConnectivityRestored() async {
        await processPendingChanges()
        await performInitialSync()
        await startRealtimeSync()
    }

    func handleUserChange() async {
        guard let context = modelContext else { return }
        syncEpoch = UUID()
        isProcessingQueue = false
        isSyncing = false
        lastSyncError = nil

        await stopRealtimeSync()

        do {
            let students = try context.fetch(FetchDescriptor<Student>())
            for student in students {
                context.delete(student)
            }

            let classes = try context.fetch(FetchDescriptor<SchoolClass>())
            for schoolClass in classes {
                context.delete(schoolClass)
            }

            let pendingChanges = try context.fetch(FetchDescriptor<PendingChange>())
            for change in pendingChanges {
                context.delete(change)
            }

            try context.save()
            lastUpdate = Date()
        } catch {
            print("[Sync] Failed to clear local data: \(error)")
            lastSyncError = "Failed to clear local data: \(error.localizedDescription)"
        }
    }

    private func requireUserId() async throws -> UUID {
        do {
            return try await userIdProvider()
        } catch {
            throw SyncError.noSession
        }
    }

    private func enqueueChange(
        entityType: EntityType,
        entityId: UUID,
        operation: OperationType,
        payload: Data,
        context: ModelContext
    ) {
        let change = PendingChange(
            entityType: entityType.rawValue,
            entityId: entityId,
            operationType: operation.rawValue,
            payload: payload
        )
        context.insert(change)
    }

    private func hasPendingChange(entityType: EntityType, entityId: UUID, context: ModelContext) -> Bool {
        let typeValue = entityType.rawValue
        let idValue = entityId
        let fetchDescriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate<PendingChange> {
                $0.entityType == typeValue && $0.entityId == idValue
            }
        )

        do {
            return try context.fetch(fetchDescriptor).isEmpty == false
        } catch {
            print("[Sync] Failed to check pending changes: \(error)")
            return false
        }
    }

    private func removePendingChanges(
        entityType: EntityType,
        entityId: UUID,
        context: ModelContext
    ) {
        let typeValue = entityType.rawValue
        let idValue = entityId
        let fetchDescriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate<PendingChange> {
                $0.entityType == typeValue && $0.entityId == idValue
            }
        )

        do {
            let pendingChanges = try context.fetch(fetchDescriptor)
            for change in pendingChanges {
                context.delete(change)
            }
        } catch {
            print("[Sync] Failed to remove pending changes: \(error)")
        }
    }

    private func removePendingStudentChanges(for classId: UUID, context: ModelContext) {
        let studentType = EntityType.student.rawValue
        let fetchDescriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate<PendingChange> {
                $0.entityType == studentType
            }
        )

        do {
            let pendingChanges = try context.fetch(fetchDescriptor)
            for change in pendingChanges {
                do {
                    let payload = try Self.decoder.decode(StudentPayload.self, from: change.payload)
                    if payload.classId == classId {
                        context.delete(change)
                    }
                } catch {
                    print("[Sync] Failed to decode pending student change: \(error)")
                }
            }
        } catch {
            print("[Sync] Failed to remove pending student changes: \(error)")
        }
    }

    private func isClassDeleted(_ classId: UUID, context: ModelContext) -> Bool {
        let fetchDescriptor = FetchDescriptor<SchoolClass>(
            predicate: #Predicate<SchoolClass> { $0.id == classId }
        )

        do {
            if let schoolClass = try context.fetch(fetchDescriptor).first {
                return schoolClass.deletedAt != nil
            }
        } catch {
            print("[Sync] Failed to check class delete status: \(error)")
        }
        return false
    }

    private func pendingEntityIds(
        from changes: [PendingChange],
        entityType: EntityType
    ) -> Set<UUID> {
        Set(changes.filter { $0.entityType == entityType.rawValue }.map { $0.entityId })
    }

    private func orderedPendingChanges(_ changes: [PendingChange]) -> [PendingChange] {
        changes.sorted { lhs, rhs in
            let lhsPriority = lhs.entityType == EntityType.schoolClass.rawValue ? 0 : 1
            let rhsPriority = rhs.entityType == EntityType.schoolClass.rawValue ? 0 : 1

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func processPendingChanges() async {
        guard let context = modelContext else { return }
        guard networkMonitor.isConnected else { return }
        guard !isProcessingQueue else { return }

        let epoch = syncEpoch
        let shouldToggleSyncState = !isSyncing
        if shouldToggleSyncState {
            isSyncing = true
        }
        isProcessingQueue = true
        defer {
            isProcessingQueue = false
            if shouldToggleSyncState {
                isSyncing = false
            }
        }

        do {
            let fetchDescriptor = FetchDescriptor<PendingChange>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
            let pendingChanges = try context.fetch(fetchDescriptor)
            guard !pendingChanges.isEmpty else { return }

            let orderedChanges = orderedPendingChanges(pendingChanges)
            let currentUserId = try await requireUserId()
            guard epoch == syncEpoch else { return }

            for change in orderedChanges {
                guard epoch == syncEpoch else { return }
                do {
                    try await pendingChangeApplier(change, currentUserId)
                    guard epoch == syncEpoch else { return }
                    context.delete(change)
                    try context.save()
                } catch {
                    change.retryCount += 1
                    lastSyncError = "Pending sync failed: \(error.localizedDescription)"
                    try context.save()
                }
            }
        } catch {
            if case SyncError.noSession = error {
                return
            }
            lastSyncError = "Failed to process pending changes: \(error.localizedDescription)"
        }
    }

    private static func defaultPendingChangeApplier(
        _ change: PendingChange,
        currentUserId: UUID
    ) async throws {
        guard let entityType = EntityType(rawValue: change.entityType),
              let operation = OperationType(rawValue: change.operationType) else {
            throw SyncError.syncFailed("Unknown pending change type")
        }

        switch entityType {
        case .schoolClass:
            let payload = try Self.decoder.decode(ClassPayload.self, from: change.payload)
            guard payload.userId == currentUserId else {
                throw SyncError.syncFailed("User mismatch for class change")
            }

            switch operation {
            case .insert:
                try await supabase
                    .from("classes")
                    .insert([
                        "id": payload.id.uuidString,
                        "class_name": payload.name,
                        "notes": payload.notes,
                        "user_id": payload.userId.uuidString
                    ])
                    .execute()
            case .update:
                try await supabase
                    .from("classes")
                    .update([
                        "class_name": payload.name,
                        "notes": payload.notes
                    ])
                    .eq("id", value: payload.id.uuidString)
                    .execute()
            case .delete:
                let deletedAt = payload.deletedAt ?? Date()
                let deletedAtString = ISO8601DateFormatter().string(from: deletedAt)
                try await supabase
                    .from("classes")
                    .update([
                        "deleted_at": deletedAtString
                    ])
                    .eq("id", value: payload.id.uuidString)
                    .execute()
            }
        case .student:
            let payload = try Self.decoder.decode(StudentPayload.self, from: change.payload)
            guard payload.userId == currentUserId else {
                throw SyncError.syncFailed("User mismatch for student change")
            }

            switch operation {
            case .insert:
                try await supabase
                    .from("students")
                    .insert([
                        "id": payload.id.uuidString,
                        "name": payload.name,
                        "notes": payload.notes,
                        "class_id": payload.classId.uuidString,
                        "user_id": payload.userId.uuidString
                    ])
                    .execute()
            case .update:
                try await supabase
                    .from("students")
                    .update([
                        "name": payload.name,
                        "notes": payload.notes,
                        "class_id": payload.classId.uuidString
                    ])
                    .eq("id", value: payload.id.uuidString)
                    .execute()
            case .delete:
                let deletedAt = payload.deletedAt ?? Date()
                let deletedAtString = ISO8601DateFormatter().string(from: deletedAt)
                try await supabase
                    .from("students")
                    .update([
                        "deleted_at": deletedAtString
                    ])
                    .eq("id", value: payload.id.uuidString)
                    .execute()
            }
        }
    }

    // MARK: - Realtime Subscriptions

    func startRealtimeSync() async {
        guard networkMonitor.isConnected else {
            print("[Realtime] Offline, skipping realtime sync")
            return
        }
        guard realtimeChannel == nil else {
            print("[Realtime] Channel already active, skipping resubscribe")
            return
        }
        guard let userId = try? await userIdProvider() else {
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
        do {
            try await channel.subscribeWithError()
        } catch {
            lastSyncError = "Realtime subscribe failed: \(error.localizedDescription)"
            print("[Realtime] Failed to subscribe: \(error)")
            return
        }

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
        currentUserId = nil
        print("[Realtime] Channel unsubscribed")
    }

    // MARK: - Handle Realtime Changes

    private func handleClassChange(_ change: AnyAction, userId: UUID) async {
        guard let context = modelContext else { return }

        do {
            switch change {
            case .insert(let action):
                print("[Realtime] Class INSERT event received")
                let record = try action.decodeRecord(as: ClassRecord.self, decoder: Self.decoder)
                await handleClassInsertRecord(record, userId: userId, context: context)

            case .update(let action):
                let record = try action.decodeRecord(as: ClassRecord.self, decoder: Self.decoder)
                guard record.userId == userId else { return }
                if let deletedAt = record.deletedAt {
                    if hasPendingChange(entityType: .schoolClass, entityId: record.id, context: context) {
                        lastSyncError = "Conflict: class deleted remotely while local changes were pending."
                        removePendingChanges(entityType: .schoolClass, entityId: record.id, context: context)
                    }
                    removePendingStudentChanges(for: record.id, context: context)
                    await softDeleteClassLocally(record.id, deletedAt: deletedAt, context: context)
                    return
                }
                if hasPendingChange(entityType: .schoolClass, entityId: record.id, context: context) {
                    print("[Realtime] Class UPDATE skipped - pending local change")
                    return
                }
                print("[Realtime] Class UPDATE: \(record.name)")
                await updateClassLocally(record, context: context)

            case .delete(let action):
                struct DeletePayload: Decodable {
                    let id: UUID
                }
                let payload = try action.decodeOldRecord(as: DeletePayload.self, decoder: Self.decoder)
                print("[Realtime] Class DELETE: \(payload.id)")
                // No user filter needed - if it exists locally, it belongs to this user
                if hasPendingChange(entityType: .schoolClass, entityId: payload.id, context: context) {
                    lastSyncError = "Conflict: class deleted remotely while local changes were pending."
                    removePendingChanges(entityType: .schoolClass, entityId: payload.id, context: context)
                }
                removePendingStudentChanges(for: payload.id, context: context)
                await softDeleteClassLocally(payload.id, deletedAt: Date(), context: context)
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
                let record = try action.decodeRecord(as: StudentRecord.self, decoder: Self.decoder)
                await handleStudentInsertRecord(record, userId: userId, context: context)

            case .update(let action):
                let record = try action.decodeRecord(as: StudentRecord.self, decoder: Self.decoder)
                guard record.userId == userId else { return }
                if let deletedAt = record.deletedAt {
                    if hasPendingChange(entityType: .student, entityId: record.id, context: context) {
                        lastSyncError = "Conflict: student deleted remotely while local changes were pending."
                        removePendingChanges(entityType: .student, entityId: record.id, context: context)
                    }
                    await softDeleteStudentLocally(record.id, deletedAt: deletedAt, context: context)
                    return
                }
                if isClassDeleted(record.classId, context: context) {
                    print("[Realtime] Student UPDATE skipped - class is deleted")
                    return
                }
                if hasPendingChange(entityType: .student, entityId: record.id, context: context) {
                    print("[Realtime] Student UPDATE skipped - pending local change")
                    return
                }
                print("[Realtime] Student UPDATE: \(record.name)")
                await updateStudentLocally(record, context: context)

            case .delete(let action):
                struct DeletePayload: Decodable {
                    let id: UUID
                }
                let payload = try action.decodeOldRecord(as: DeletePayload.self, decoder: Self.decoder)
                print("[Realtime] Student DELETE: \(payload.id)")
                // No user filter needed - if it exists locally, it belongs to this user
                if hasPendingChange(entityType: .student, entityId: payload.id, context: context) {
                    lastSyncError = "Conflict: student deleted remotely while local changes were pending."
                    removePendingChanges(entityType: .student, entityId: payload.id, context: context)
                }
                await softDeleteStudentLocally(payload.id, deletedAt: Date(), context: context)
            }
        } catch {
            print("[Realtime] Error handling student change: \(error)")
            lastSyncError = "Failed to handle student change: \(error.localizedDescription)"
        }
    }

    func handleClassInsertRecord(_ record: ClassRecord, userId: UUID, context: ModelContext) async {
        print("[Realtime] Class INSERT decoded: \(record.name), userId: \(record.userId), currentUser: \(userId)")
        // Filter client-side: only process changes for this user
        guard record.userId == userId else {
            print("[Realtime] Class INSERT skipped - different user")
            return
        }
        if hasPendingChange(entityType: .schoolClass, entityId: record.id, context: context) {
            print("[Realtime] Class INSERT skipped - pending local change")
            return
        }
        print("[Realtime] Class INSERT processing: \(record.name)")
        await insertClassLocally(record, context: context)
    }

    func handleStudentInsertRecord(_ record: StudentRecord, userId: UUID, context: ModelContext) async {
        guard record.userId == userId else { return }
        if isClassDeleted(record.classId, context: context) {
            print("[Realtime] Student INSERT skipped - class is deleted")
            return
        }
        if hasPendingChange(entityType: .student, entityId: record.id, context: context) {
            print("[Realtime] Student INSERT skipped - pending local change")
            return
        }
        print("[Realtime] Student INSERT: \(record.name)")
        await insertStudentLocally(record, context: context)
    }

    // MARK: - Local Database Operations

    func insertClassLocally(_ record: ClassRecord, context: ModelContext) async {
        let recordId = record.id
        let existingFetch = FetchDescriptor<SchoolClass>(
            predicate: #Predicate<SchoolClass> { $0.id == recordId }
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
                    updatedAt: record.updatedAt,
                    deletedAt: record.deletedAt
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

    func updateClassLocally(_ record: ClassRecord, context: ModelContext) async {
        let recordId = record.id
        let fetchDescriptor = FetchDescriptor<SchoolClass>(
            predicate: #Predicate<SchoolClass> { $0.id == recordId }
        )

        do {
            if let existingClass = try context.fetch(fetchDescriptor).first {
                if existingClass.deletedAt != nil && record.deletedAt == nil {
                    print("[Realtime] Class UPDATE skipped - local record is deleted")
                    lastSyncError = "Conflict: class updated remotely after local deletion."
                    return
                }
                existingClass.name = record.name
                existingClass.notes = record.notes
                existingClass.updatedAt = record.updatedAt
                existingClass.deletedAt = record.deletedAt
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Updated class locally: \(record.name)")
            }
        } catch {
            print("[Realtime] Error updating class: \(error)")
        }
    }

    func softDeleteClassLocally(_ id: UUID, deletedAt: Date, context: ModelContext) async {
        let fetchDescriptor = FetchDescriptor<SchoolClass>(
            predicate: #Predicate<SchoolClass> { $0.id == id }
        )

        do {
            if let existingClass = try context.fetch(fetchDescriptor).first {
                existingClass.deletedAt = deletedAt
                existingClass.updatedAt = deletedAt

                let classId = existingClass.id
                let studentFetch = FetchDescriptor<Student>(
                    predicate: #Predicate<Student> { $0.classId == classId }
                )
                let students = try context.fetch(studentFetch)
                for student in students {
                    student.deletedAt = deletedAt
                    student.updatedAt = deletedAt
                }

                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Soft-deleted class locally: \(id)")
            }
        } catch {
            print("[Realtime] Error soft-deleting class: \(error)")
        }
    }

    func insertStudentLocally(_ record: StudentRecord, context: ModelContext) async {
        let recordId = record.id
        let existingFetch = FetchDescriptor<Student>(
            predicate: #Predicate<Student> { $0.id == recordId }
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
                    updatedAt: record.updatedAt,
                    deletedAt: record.deletedAt
                )

                // Link to class
                let classId = record.classId
                let classFetch = FetchDescriptor<SchoolClass>(
                    predicate: #Predicate<SchoolClass> { $0.id == classId }
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

    func updateStudentLocally(_ record: StudentRecord, context: ModelContext) async {
        let recordId = record.id
        let fetchDescriptor = FetchDescriptor<Student>(
            predicate: #Predicate<Student> { $0.id == recordId }
        )

        do {
            if let existingStudent = try context.fetch(fetchDescriptor).first {
                if existingStudent.deletedAt != nil && record.deletedAt == nil {
                    print("[Realtime] Student UPDATE skipped - local record is deleted")
                    lastSyncError = "Conflict: student updated remotely after local deletion."
                    return
                }
                existingStudent.name = record.name
                existingStudent.notes = record.notes
                existingStudent.updatedAt = record.updatedAt
                existingStudent.deletedAt = record.deletedAt
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Updated student locally: \(record.name)")
            }
        } catch {
            print("[Realtime] Error updating student: \(error)")
        }
    }

    func softDeleteStudentLocally(_ id: UUID, deletedAt: Date, context: ModelContext) async {
        let fetchDescriptor = FetchDescriptor<Student>(
            predicate: #Predicate<Student> { $0.id == id }
        )

        do {
            if let existingStudent = try context.fetch(fetchDescriptor).first {
                existingStudent.deletedAt = deletedAt
                existingStudent.updatedAt = deletedAt
                try context.save()
                lastUpdate = Date()  // Trigger UI refresh
                print("[Realtime] Soft-deleted student locally: \(id)")
            }
        } catch {
            print("[Realtime] Error soft-deleting student: \(error)")
        }
    }

    // MARK: - Initial Sync

    func applyInitialSync(
        classRecords: [ClassRecord],
        studentRecords: [StudentRecord],
        pendingClassIds: Set<UUID>,
        pendingStudentIds: Set<UUID>,
        context: ModelContext
    ) throws {
        var deletedClassIds = Set<UUID>()
        // Sync classes
        for record in classRecords {
            let recordId = record.id
            let fetchDescriptor = FetchDescriptor<SchoolClass>(
                predicate: #Predicate<SchoolClass> { $0.id == recordId }
            )
            let existing = try context.fetch(fetchDescriptor)
            if let deletedAt = record.deletedAt {
                deletedClassIds.insert(record.id)
                if hasPendingChange(entityType: .schoolClass, entityId: record.id, context: context) {
                    lastSyncError = "Conflict: class deleted remotely while local changes were pending."
                    removePendingChanges(entityType: .schoolClass, entityId: record.id, context: context)
                }
                removePendingStudentChanges(for: record.id, context: context)

                if let existingClass = existing.first {
                    existingClass.deletedAt = deletedAt
                    existingClass.updatedAt = record.updatedAt

                    let classId = record.id
                    let studentFetch = FetchDescriptor<Student>(
                        predicate: #Predicate<Student> { $0.classId == classId }
                    )
                    let students = try context.fetch(studentFetch)
                    for student in students {
                        student.deletedAt = deletedAt
                        student.updatedAt = record.updatedAt
                    }
                }
                continue
            }

            if pendingClassIds.contains(record.id) {
                continue
            }

            if let existingClass = existing.first {
                // Update if remote is newer
                if record.updatedAt > existingClass.updatedAt {
                    existingClass.name = record.name
                    existingClass.notes = record.notes
                    existingClass.updatedAt = record.updatedAt
                    existingClass.deletedAt = nil
                }
            } else {
                // Insert new
                let newClass = SchoolClass(
                    id: record.id,
                    name: record.name,
                    notes: record.notes,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    deletedAt: record.deletedAt
                )
                context.insert(newClass)
            }
        }

        // Sync students
        for record in studentRecords {
            let recordId = record.id
            let fetchDescriptor = FetchDescriptor<Student>(
                predicate: #Predicate<Student> { $0.id == recordId }
            )
            let existing = try context.fetch(fetchDescriptor)
            if let deletedAt = record.deletedAt {
                if hasPendingChange(entityType: .student, entityId: record.id, context: context) {
                    lastSyncError = "Conflict: student deleted remotely while local changes were pending."
                    removePendingChanges(entityType: .student, entityId: record.id, context: context)
                }

                if let existingStudent = existing.first {
                    existingStudent.deletedAt = deletedAt
                    existingStudent.updatedAt = record.updatedAt
                }
                continue
            }

            if deletedClassIds.contains(record.classId) {
                continue
            }

            if pendingStudentIds.contains(record.id) {
                continue
            }

            if let existingStudent = existing.first {
                // Update if remote is newer
                if record.updatedAt > existingStudent.updatedAt {
                    existingStudent.name = record.name
                    existingStudent.notes = record.notes
                    existingStudent.updatedAt = record.updatedAt
                    existingStudent.deletedAt = nil
                }
            } else {
                // Insert new
                let newStudent = Student(
                    id: record.id,
                    name: record.name,
                    notes: record.notes,
                    classId: record.classId,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    deletedAt: record.deletedAt
                )

                // Link to class
                let classId = record.classId
                let classFetch = FetchDescriptor<SchoolClass>(
                    predicate: #Predicate<SchoolClass> { $0.id == classId }
                )
                if let schoolClass = try context.fetch(classFetch).first {
                    newStudent.schoolClass = schoolClass
                }

                context.insert(newStudent)
            }
        }

        try context.save()
        lastUpdate = Date()
    }

    func performInitialSync() async {
        guard let context = modelContext else { return }
        guard networkMonitor.isConnected else {
            print("[Sync] Offline, skipping initial sync")
            return
        }
        isSyncing = true
        let epoch = syncEpoch
        defer { isSyncing = false }

        do {
            let pendingChanges = try context.fetch(FetchDescriptor<PendingChange>())
            let pendingClassIds = pendingEntityIds(from: pendingChanges, entityType: .schoolClass)
            let pendingStudentIds = pendingEntityIds(from: pendingChanges, entityType: .student)

            await processPendingChanges()
            guard epoch == syncEpoch else { return }
            let userId = try await requireUserId()
            guard epoch == syncEpoch else { return }

            // Fetch classes from Supabase
            let classRecords: [ClassRecord] = try await supabase
                .from("classes")
                .select()
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            guard epoch == syncEpoch else { return }

            // Fetch students from Supabase
            let studentRecords: [StudentRecord] = try await supabase
                .from("students")
                .select()
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            guard epoch == syncEpoch else { return }

            try applyInitialSync(
                classRecords: classRecords,
                studentRecords: studentRecords,
                pendingClassIds: pendingClassIds,
                pendingStudentIds: pendingStudentIds,
                context: context
            )
        } catch {
            if case SyncError.noSession = error {
                return
            }
            lastSyncError = "Initial sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - CRUD Operations (local-first with queued sync)

    func createClass(name: String, notes: String) async throws -> SchoolClass {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await requireUserId()
        let newClass = SchoolClass(name: name, notes: notes)
        let payload = ClassPayload(
            id: newClass.id,
            name: newClass.name,
            notes: newClass.notes,
            userId: userId,
            deletedAt: nil
        )

        context.insert(newClass)
        enqueueChange(
            entityType: .schoolClass,
            entityId: newClass.id,
            operation: .insert,
            payload: try Self.encoder.encode(payload),
            context: context
        )
        try context.save()
        context.processPendingChanges()
        lastUpdate = Date()
        Task {
            await processPendingChanges()
        }

        return newClass
    }

    func updateClass(_ schoolClass: SchoolClass) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await requireUserId()
        schoolClass.updatedAt = Date()
        let payload = ClassPayload(
            id: schoolClass.id,
            name: schoolClass.name,
            notes: schoolClass.notes,
            userId: userId,
            deletedAt: nil
        )

        enqueueChange(
            entityType: .schoolClass,
            entityId: schoolClass.id,
            operation: .update,
            payload: try Self.encoder.encode(payload),
            context: context
        )
        try context.save()
        context.processPendingChanges()
        lastUpdate = Date()
        Task {
            await processPendingChanges()
        }
    }

    func deleteClass(_ schoolClass: SchoolClass) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await requireUserId()
        let deletedAt = Date()
        schoolClass.deletedAt = deletedAt
        schoolClass.updatedAt = deletedAt
        for student in schoolClass.students {
            student.deletedAt = deletedAt
            student.updatedAt = deletedAt
        }
        let payload = ClassPayload(
            id: schoolClass.id,
            name: schoolClass.name,
            notes: schoolClass.notes,
            userId: userId,
            deletedAt: deletedAt
        )

        removePendingStudentChanges(for: schoolClass.id, context: context)
        enqueueChange(
            entityType: .schoolClass,
            entityId: schoolClass.id,
            operation: .delete,
            payload: try Self.encoder.encode(payload),
            context: context
        )
        try context.save()
        context.processPendingChanges()
        lastUpdate = Date()
        Task {
            await processPendingChanges()
        }
    }

    func createStudent(name: String, notes: String, in schoolClass: SchoolClass) async throws -> Student {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await requireUserId()
        let newStudent = Student(name: name, notes: notes, classId: schoolClass.id)
        newStudent.schoolClass = schoolClass
        let payload = StudentPayload(
            id: newStudent.id,
            name: newStudent.name,
            notes: newStudent.notes,
            classId: newStudent.classId,
            userId: userId,
            deletedAt: nil
        )

        context.insert(newStudent)
        enqueueChange(
            entityType: .student,
            entityId: newStudent.id,
            operation: .insert,
            payload: try Self.encoder.encode(payload),
            context: context
        )
        try context.save()
        context.processPendingChanges()
        lastUpdate = Date()
        Task {
            await processPendingChanges()
        }

        return newStudent
    }

    func updateStudent(_ student: Student) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await requireUserId()
        student.updatedAt = Date()
        let payload = StudentPayload(
            id: student.id,
            name: student.name,
            notes: student.notes,
            classId: student.classId,
            userId: userId,
            deletedAt: nil
        )

        enqueueChange(
            entityType: .student,
            entityId: student.id,
            operation: .update,
            payload: try Self.encoder.encode(payload),
            context: context
        )
        try context.save()
        context.processPendingChanges()
        lastUpdate = Date()
        Task {
            await processPendingChanges()
        }
    }

    func deleteStudent(_ student: Student) async throws {
        guard let context = modelContext else {
            throw SyncError.noContext
        }

        let userId = try await requireUserId()
        let deletedAt = Date()
        student.deletedAt = deletedAt
        student.updatedAt = deletedAt
        let payload = StudentPayload(
            id: student.id,
            name: student.name,
            notes: student.notes,
            classId: student.classId,
            userId: userId,
            deletedAt: deletedAt
        )

        enqueueChange(
            entityType: .student,
            entityId: student.id,
            operation: .delete,
            payload: try Self.encoder.encode(payload),
            context: context
        )
        try context.save()
        context.processPendingChanges()
        lastUpdate = Date()
        Task {
            await processPendingChanges()
        }
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
    let deletedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name = "class_name"
        case notes
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
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
    let deletedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case notes
        case classId = "class_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case noContext
    case noSession
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .noContext:
            return "No model context available"
        case .noSession:
            return "No authenticated session available"
        case .syncFailed(let message):
            return "Sync failed: \(message)"
        }
    }
}

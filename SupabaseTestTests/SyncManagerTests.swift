import XCTest
import SwiftData
@testable import SupabaseTest

@MainActor
final class SyncManagerTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: SchoolClass.self,
            Student.self,
            PendingChange.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
    }

    private func makeSyncManager() -> SyncManager {
        let monitor = TestNetworkMonitor(isConnected: true)
        return SyncManager(
            networkMonitor: monitor,
            userIdProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
            pendingChangeApplier: { _, _ in }
        )
    }

    func testClassRecordInsertMapping() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncManager = makeSyncManager()
        syncManager.configure(modelContext: context)

        let classId = UUID()
        let userId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let record = ClassRecord(
            id: classId,
            name: "Biology",
            notes: "Lab required",
            userId: userId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        await syncManager.insertClassLocally(record, context: context)

        let fetch = FetchDescriptor<SchoolClass>(predicate: #Predicate { $0.id == classId })
        let results = try context.fetch(fetch)
        XCTAssertEqual(results.count, 1)

        let inserted = try XCTUnwrap(results.first)
        XCTAssertEqual(inserted.name, "Biology")
        XCTAssertEqual(inserted.notes, "Lab required")
        XCTAssertEqual(inserted.createdAt, createdAt)
        XCTAssertEqual(inserted.updatedAt, updatedAt)
    }

    func testApplyInitialSyncInsertsAndLinksStudent() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncManager = makeSyncManager()
        syncManager.configure(modelContext: context)

        let classId = UUID()
        let userId = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let classRecord = ClassRecord(
            id: classId,
            name: "Math 101",
            notes: "",
            userId: userId,
            createdAt: now,
            updatedAt: now
        )
        let studentId = UUID()
        let studentRecord = StudentRecord(
            id: studentId,
            name: "Ada Lovelace",
            notes: "",
            classId: classId,
            userId: userId,
            createdAt: now,
            updatedAt: now
        )

        try syncManager.applyInitialSync(
            classRecords: [classRecord],
            studentRecords: [studentRecord],
            pendingClassIds: [],
            pendingStudentIds: [],
            context: context
        )

        let studentFetch = FetchDescriptor<Student>(predicate: #Predicate { $0.id == studentId })
        let students = try context.fetch(studentFetch)
        XCTAssertEqual(students.count, 1)

        let student = try XCTUnwrap(students.first)
        XCTAssertEqual(student.schoolClass?.id, classId)
    }

    func testRealtimeClassInsertSkipsPendingChange() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let syncManager = makeSyncManager()
        syncManager.configure(modelContext: context)

        let classId = UUID()
        let userId = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ClassRecord(
            id: classId,
            name: "History",
            notes: "",
            userId: userId,
            createdAt: now,
            updatedAt: now
        )

        let pending = PendingChange(
            entityType: "class",
            entityId: classId,
            operationType: "insert",
            payload: Data()
        )
        context.insert(pending)
        try context.save()

        await syncManager.handleClassInsertRecord(record, userId: userId, context: context)

        let fetch = FetchDescriptor<SchoolClass>(predicate: #Predicate { $0.id == classId })
        let results = try context.fetch(fetch)
        XCTAssertEqual(results.count, 0)
    }
}

@MainActor
final class TestNetworkMonitor: NetworkMonitoring {
    private let connected: Bool

    var isConnected: Bool {
        connected
    }

    init(isConnected: Bool) {
        self.connected = isConnected
    }

    func setConnectivityRestoredHandler(_ handler: @escaping @MainActor () async -> Void) {
    }
}

import SwiftUI
import SwiftData

struct ClassDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncManager: SyncManager

    @Bindable var schoolClass: SchoolClass
    @State private var students: [Student] = []

    @State private var showAddStudent = false
    @State private var showEditClass = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        List {
            Section("Class Info") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(schoolClass.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if !schoolClass.notes.isEmpty {
                        Text(schoolClass.notes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Students (\(students.count))") {
                if students.isEmpty {
                    Text("No students yet")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(students) { student in
                        StudentRowView(student: student)
                    }
                    .onDelete(perform: deleteStudents)
                }
            }
        }
        .navigationTitle(schoolClass.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAddStudent = true
                    } label: {
                        Label("Add Student", systemImage: "person.badge.plus")
                    }

                    Button {
                        showEditClass = true
                    } label: {
                        Label("Edit Class", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddStudent) {
            AddStudentSheet(schoolClass: schoolClass)
        }
        .sheet(isPresented: $showEditClass) {
            EditClassSheet(schoolClass: schoolClass)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .task {
            reloadStudents()
        }
        .onChange(of: syncManager.lastUpdate) { _, _ in
            reloadStudents()
        }
    }

    @MainActor
    private func reloadStudents() {
        let classId = schoolClass.id
        let fetchDescriptor = FetchDescriptor<Student>(
            predicate: #Predicate<Student> { $0.classId == classId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.name)]
        )
        do {
            students = try modelContext.fetch(fetchDescriptor)
        } catch {
            errorMessage = "Failed to load students: \(error.localizedDescription)"
            showError = true
        }
    }

    private func deleteStudents(at offsets: IndexSet) {
        let targets = offsets.map { students[$0] }
        Task { @MainActor in
            for student in targets {
                do {
                    try await syncManager.deleteStudent(student)
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

struct StudentRowView: View {
    let student: Student

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(student.name)
                .font(.body)

            if !student.notes.isEmpty {
                Text(student.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let container = try! ModelContainer(
        for: SchoolClass.self,
        Student.self,
        PendingChange.self,
        configurations: .init(isStoredInMemoryOnly: true)
    )
    let schoolClass = SchoolClass(name: "Math 101", notes: "Advanced calculus")
    container.mainContext.insert(schoolClass)

    return NavigationStack {
        ClassDetailView(schoolClass: schoolClass)
    }
    .modelContainer(container)
    .environmentObject(SyncManager())
}

import SwiftUI
import SwiftData

struct ClassDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncManager: SyncManager

    @Bindable var schoolClass: SchoolClass

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

            Section("Students (\(schoolClass.students.count))") {
                if schoolClass.students.isEmpty {
                    Text("No students yet")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(schoolClass.students.sorted(by: { $0.name < $1.name })) { student in
                        StudentRowView(student: student)
                    }
                    .onDelete(perform: deleteStudents)
                }
            }
        }
        .id(syncManager.lastUpdate)  // Force refresh when realtime updates come in
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
    }

    private func deleteStudents(at offsets: IndexSet) {
        let sortedStudents = schoolClass.students.sorted(by: { $0.name < $1.name })
        Task {
            for index in offsets {
                let student = sortedStudents[index]
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
    let container = try! ModelContainer(for: SchoolClass.self, Student.self, configurations: .init(isStoredInMemoryOnly: true))
    let schoolClass = SchoolClass(name: "Math 101", notes: "Advanced calculus")
    container.mainContext.insert(schoolClass)

    return NavigationStack {
        ClassDetailView(schoolClass: schoolClass)
    }
    .modelContainer(container)
    .environmentObject(SyncManager())
}

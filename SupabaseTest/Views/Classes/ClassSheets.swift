import SwiftUI
import SwiftData

// MARK: - Add Class Sheet

struct AddClassSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncManager: SyncManager

    @State private var name = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Class Details") {
                    TextField("Class Name", text: $name)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveClass()
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func saveClass() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                _ = try await syncManager.createClass(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - Edit Class Sheet

struct EditClassSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncManager: SyncManager

    @Bindable var schoolClass: SchoolClass

    @State private var name: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(schoolClass: SchoolClass) {
        self.schoolClass = schoolClass
        _name = State(initialValue: schoolClass.name)
        _notes = State(initialValue: schoolClass.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Class Details") {
                    TextField("Class Name", text: $name)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveClass()
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func saveClass() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                schoolClass.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                schoolClass.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                try await syncManager.updateClass(schoolClass)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - Add Student Sheet

struct AddStudentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncManager: SyncManager

    let schoolClass: SchoolClass

    @State private var name = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Student Details") {
                    TextField("Name", text: $name)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Student")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveStudent()
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func saveStudent() {
        isSaving = true
        errorMessage = nil

        Task {
            do {
                _ = try await syncManager.createStudent(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                    in: schoolClass
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - Previews

#Preview("Add Class") {
    AddClassSheet()
        .environmentObject(SyncManager())
}

#Preview("Add Student") {
    let container = try! ModelContainer(for: SchoolClass.self, Student.self, configurations: .init(isStoredInMemoryOnly: true))
    let schoolClass = SchoolClass(name: "Math 101", notes: "")
    container.mainContext.insert(schoolClass)

    return AddStudentSheet(schoolClass: schoolClass)
        .modelContainer(container)
        .environmentObject(SyncManager())
}

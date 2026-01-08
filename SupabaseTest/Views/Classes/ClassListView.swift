import SwiftUI
import SwiftData

struct ClassListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncManager: SyncManager
    @EnvironmentObject private var authManager: AuthManager

    @Query(sort: \SchoolClass.name) private var classes: [SchoolClass]

    @State private var showAddClass = false
    @State private var showError = false
    @State private var errorMessage = ""

    private let sampleClasses = [
        ("Math 101", "Introduction to Algebra"),
        ("English Literature", "Classic novels and poetry"),
        ("Biology", "Life sciences fundamentals"),
        ("World History", "Ancient to modern civilizations"),
        ("Chemistry", "Elements and reactions"),
        ("Physics", "Mechanics and thermodynamics"),
        ("Spanish I", "Beginning Spanish language"),
        ("Art History", "Renaissance to modern art"),
        ("Computer Science", "Programming basics"),
        ("Music Theory", "Notes, scales, and composition"),
        ("Physical Education", "Fitness and sports"),
        ("Psychology", "Introduction to human behavior"),
        ("Economics", "Micro and macroeconomics"),
        ("Geography", "World regions and cultures"),
        ("French II", "Intermediate French"),
        ("Creative Writing", "Fiction and poetry workshop"),
        ("Calculus", "Derivatives and integrals"),
        ("Environmental Science", "Ecology and conservation"),
        ("Drama", "Acting and theater production"),
        ("Statistics", "Data analysis and probability")
    ]

    var body: some View {
        NavigationStack {
            Group {
                if classes.isEmpty {
                    ContentUnavailableView(
                        "No Classes",
                        systemImage: "folder",
                        description: Text("Tap the + button to create your first class.")
                    )
                } else {
                    List {
                        ForEach(classes) { schoolClass in
                            NavigationLink(value: schoolClass) {
                                ClassRowView(schoolClass: schoolClass)
                            }
                        }
                        .onDelete(perform: deleteClasses)
                    }
                }
            }
            .id(syncManager.lastUpdate)  // Force refresh when realtime updates come in
            .navigationTitle("Classes")
            .navigationDestination(for: SchoolClass.self) { schoolClass in
                ClassDetailView(schoolClass: schoolClass)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await authManager.signOut()
                        }
                    } label: {
                        Text("Sign Out")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            addRandomClass()
                        } label: {
                            Image(systemName: "dice")
                        }

                        Button {
                            showAddClass = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddClass) {
                AddClassSheet()
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            .overlay {
                if syncManager.isSyncing {
                    ProgressView("Syncing...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(8)
                }
            }
            .task {
                syncManager.configure(modelContext: modelContext)
                await syncManager.performInitialSync()
                await syncManager.startRealtimeSync()
            }
        }
    }

    private func deleteClasses(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let schoolClass = classes[index]
                do {
                    try await syncManager.deleteClass(schoolClass)
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func addRandomClass() {
        guard let randomClass = sampleClasses.randomElement() else { return }
        Task {
            do {
                _ = try await syncManager.createClass(
                    name: randomClass.0,
                    notes: randomClass.1
                )
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

struct ClassRowView: View {
    let schoolClass: SchoolClass

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(schoolClass.name)
                .font(.headline)

            HStack {
                Text("\(schoolClass.students.count) students")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !schoolClass.notes.isEmpty {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(schoolClass.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ClassListView()
        .modelContainer(for: [SchoolClass.self, Student.self, PendingChange.self], inMemory: true)
        .environmentObject(SyncManager())
        .environmentObject(AuthManager())
}

//
//  SupabaseTestApp.swift
//  SupabaseTest
//
//  Created by Xavier De Leon on 1/4/26.
//

import SwiftUI
import SwiftData
import Auth

@main
struct SupabaseTestApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var syncManager = SyncManager()
    private let modelContainer: ModelContainer

    private static let modelConfigurationName = "SupabaseTest"
    private static let schema = Schema([
        SchoolClass.self,
        Student.self,
        PendingChange.self
    ])

    init() {
        let configuration = ModelConfiguration(Self.modelConfigurationName, schema: Self.schema)
        do {
            modelContainer = try ModelContainer(for: Self.schema, configurations: configuration)
        } catch {
            fatalError("Could not configure SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environmentObject(syncManager)
        }
        .modelContainer(modelContainer)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager
    @State private var lastUserId: UUID?

    var body: some View {
        Group {
            switch authManager.authState {
            case .loading:
                LoadingView()
            case .authenticated:
                ClassListView()
            case .unauthenticated:
                LoginView()
            }
        }
        .animation(.easeInOut, value: authStateKey)
        .task {
            await handleAuthChange()
        }
        .onChange(of: authUserId) { _, _ in
            Task {
                await handleAuthChange()
            }
        }
    }

    private var authStateKey: String {
        switch authManager.authState {
        case .loading:
            return "loading"
        case .authenticated:
            return "authenticated"
        case .unauthenticated:
            return "unauthenticated"
        }
    }

    private var authUserId: UUID? {
        if case .authenticated(let user) = authManager.authState {
            return user.id
        }
        return nil
    }

    private func handleAuthChange() async {
        syncManager.configure(modelContext: modelContext)

        let currentUserId = authUserId
        guard currentUserId != lastUserId else { return }

        if lastUserId != nil {
            await syncManager.handleUserChange()
        }

        lastUserId = currentUserId
        guard currentUserId != nil else { return }

        await syncManager.performInitialSync()
        await syncManager.startRealtimeSync()
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

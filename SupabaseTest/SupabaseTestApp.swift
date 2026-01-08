//
//  SupabaseTestApp.swift
//  SupabaseTest
//
//  Created by Xavier De Leon on 1/4/26.
//

import SwiftUI
import SwiftData

@main
struct SupabaseTestApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var syncManager = SyncManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authManager)
                .environmentObject(syncManager)
        }
        .modelContainer(for: [SchoolClass.self, Student.self, PendingChange.self])
    }
}

struct RootView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager

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

import SwiftUI
import Auth

struct MainView: View {
    @EnvironmentObject private var authManager: AuthManager

    let user: User

    @State private var isLoggingOut = false
    @State private var showLogoutConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteConfirmationEmail = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // User Info
                VStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 100))
                        .foregroundStyle(.blue)

                    Text("Welcome!")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    if let email = user.email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // User Details Card
                VStack(alignment: .leading, spacing: 12) {
                    UserDetailRow(label: "User ID", value: user.id.uuidString)

                    UserDetailRow(
                        label: "Account Created",
                        value: user.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )

                    if let lastSignIn = user.lastSignInAt {
                        UserDetailRow(
                            label: "Last Sign In",
                            value: lastSignIn.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    UserDetailRow(
                        label: "Email Verified",
                        value: user.emailConfirmedAt != nil ? "Yes" : "No"
                    )
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()

                // Error Message
                if let error = authManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Logout Button
                Button {
                    showLogoutConfirmation = true
                } label: {
                    Group {
                        if isLoggingOut {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                .disabled(isLoggingOut || isDeleting)
                .padding(.horizontal)

                // Delete Account Button
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Group {
                        if isDeleting {
                            ProgressView()
                                .tint(.red)
                        } else {
                            Label("Delete Account", systemImage: "trash")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .foregroundStyle(.red)
                    .cornerRadius(12)
                }
                .disabled(isLoggingOut || isDeleting)
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .navigationTitle("Profile")
            .confirmationDialog(
                "Sign Out",
                isPresented: $showLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        isLoggingOut = true
                        await authManager.signOut()
                        isLoggingOut = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out?")
            }
            .sheet(isPresented: $showDeleteConfirmation) {
                DeleteAccountSheet(
                    userEmail: user.email ?? "",
                    confirmationEmail: $deleteConfirmationEmail,
                    isDeleting: $isDeleting,
                    onDelete: {
                        Task {
                            isDeleting = true
                            await authManager.deleteAccount()
                            isDeleting = false
                            showDeleteConfirmation = false
                        }
                    },
                    onCancel: {
                        deleteConfirmationEmail = ""
                        showDeleteConfirmation = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }

    private var isDeleteEnabled: Bool {
        deleteConfirmationEmail.lowercased() == user.email?.lowercased()
    }
}

struct DeleteAccountSheet: View {
    let userEmail: String
    @Binding var confirmationEmail: String
    @Binding var isDeleting: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var isDeleteEnabled: Bool {
        confirmationEmail.lowercased() == userEmail.lowercased() && !userEmail.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Delete Account")
                .font(.title2)
                .fontWeight(.bold)

            Text("This action cannot be undone. This will permanently delete your account, remove you from all groups, and erase all your data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Type")
                    Text(userEmail)
                        .foregroundStyle(.red)
                    Text("to confirm:")
                }
                .font(.subheadline)

                TextField("Type your email", text: $confirmationEmail)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .padding()
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.5), lineWidth: 1)
                    )
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .foregroundStyle(.primary)
                .cornerRadius(8)

                Button {
                    onDelete()
                } label: {
                    if isDeleting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Delete Account")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isDeleteEnabled ? Color.red : Color.red.opacity(0.5))
                .foregroundStyle(.white)
                .cornerRadius(8)
                .disabled(!isDeleteEnabled || isDeleting)
            }
        }
        .padding(24)
    }
}

struct UserDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// Preview removed - User struct requires complex initialization

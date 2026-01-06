import SwiftUI

struct ResendVerificationView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isLoading = false
    @State private var showSuccessAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.purple)

                    Text("Resend Verification")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Enter your email to receive a new verification link")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 40)

                // Form
                VStack(spacing: 16) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                // Error Message
                if let error = authManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Resend Button
                Button {
                    Task {
                        isLoading = true
                        await authManager.resendVerificationEmail(email: email)
                        isLoading = false

                        if authManager.successMessage != nil {
                            showSuccessAlert = true
                        }
                    }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Resend Verification Email")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isFormValid ? Color.purple : Color.purple.opacity(0.5))
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                .disabled(!isFormValid || isLoading)
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                // Back to Sign In
                Button {
                    dismiss()
                } label: {
                    Text("Back to Sign In")
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }

                Spacer(minLength: 40)
            }
        }
        .navigationTitle("Resend Verification")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Email Sent", isPresented: $showSuccessAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text(authManager.successMessage ?? "Please check your email for the verification link.")
        }
        .onAppear {
            authManager.clearMessages()
        }
    }

    private var isFormValid: Bool {
        !email.isEmpty && email.contains("@")
    }
}

#Preview {
    NavigationStack {
        ResendVerificationView()
            .environmentObject(AuthManager())
    }
}

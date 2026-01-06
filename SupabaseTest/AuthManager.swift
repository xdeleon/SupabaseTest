import Combine
import Foundation
import Supabase
import Auth

enum AuthState {
    case loading
    case authenticated(User)
    case unauthenticated
}

@MainActor
final class AuthManager: ObservableObject {
    @Published var authState: AuthState = .loading
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private var authStateTask: Task<Void, Never>?

    init() {
        Task {
            await checkSession()
            await listenToAuthChanges()
        }
    }

    deinit {
        authStateTask?.cancel()
    }

    // MARK: - Session Management

    func checkSession() async {
        do {
            let session = try await supabase.auth.session
            authState = .authenticated(session.user)
        } catch {
            authState = .unauthenticated
        }
    }

    private func listenToAuthChanges() async {
        authStateTask = Task {
            for await (event, session) in supabase.auth.authStateChanges {
                guard !Task.isCancelled else { return }

                switch event {
                case .initialSession, .signedIn:
                    if let user = session?.user {
                        authState = .authenticated(user)
                    } else {
                        authState = .unauthenticated
                    }
                case .signedOut:
                    authState = .unauthenticated
                case .tokenRefreshed, .userUpdated:
                    if let user = session?.user {
                        authState = .authenticated(user)
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Sign Up

    func signUp(email: String, password: String) async {
        clearMessages()

        do {
            let response = try await supabase.auth.signUp(
                email: email,
                password: password
            )

            if response.user.emailConfirmedAt == nil {
                successMessage = "Please check your email to confirm your account."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async {
        clearMessages()

        do {
            let session = try await supabase.auth.signIn(
                email: email,
                password: password
            )
            authState = .authenticated(session.user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        clearMessages()

        do {
            try await supabase.auth.signOut()
            authState = .unauthenticated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Password Reset

    func resetPassword(email: String) async {
        clearMessages()

        do {
            try await supabase.auth.resetPasswordForEmail(email)
            successMessage = "Password reset email sent. Please check your inbox."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Resend Verification Email

    func resendVerificationEmail(email: String) async {
        clearMessages()

        do {
            try await supabase.auth.resend(
                email: email,
                type: .signup
            )
            successMessage = "Verification email sent. Please check your inbox."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Delete Account

    func deleteAccount() async {
        clearMessages()

        do {
            struct DeleteResponse: Decodable {
                let success: Bool?
                let error: String?
            }

            // Call the delete-account edge function (user is extracted from JWT)
            let response: DeleteResponse = try await supabase.functions.invoke("delete-account")

            if let error = response.error {
                errorMessage = error
                return
            }

            // Sign out locally
            authState = .unauthenticated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}

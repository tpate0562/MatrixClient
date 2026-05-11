import AppKit
import AuthenticationServices

/// Wrapper around `ASWebAuthenticationSession` that opens a system browser modal, waits
/// for the homeserver's OAuth redirect, and returns the callback URL. Throws on user
/// cancel.
enum AuthWebSession {
    static func start(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.noCallback)
                }
            }
            session.prefersEphemeralWebBrowserSession = false   // Keep Google's session so
                                                                // the user doesn't have to
                                                                // re-enter their password.
            session.presentationContextProvider = PresentationContext.shared
            if !session.start() {
                continuation.resume(throwing: AuthError.failedToStart)
            }
        }
    }

    enum AuthError: LocalizedError {
        case failedToStart
        case noCallback
        var errorDescription: String? {
            switch self {
            case .failedToStart: return "Couldn't start the sign-in window"
            case .noCallback:    return "Sign-in window closed without returning a result"
            }
        }
    }

    /// ASWebAuthenticationSession needs a window to anchor itself on. We give it the key
    /// window of the active app.
    final class PresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = PresentationContext()
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}

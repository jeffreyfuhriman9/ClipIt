import Foundation
import Supabase
import Combine

@MainActor
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    @Published private(set) var isConfigured = SupabaseConfig.isConfigured
    @Published private(set) var currentUserID: UUID?
    @Published private(set) var currentUserEmail: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: String?

    private let client: SupabaseClient?

    private init() {
        if let url = SupabaseConfig.url, let key = SupabaseConfig.anonKey {
            client = SupabaseClient(supabaseURL: url, supabaseKey: key)
            isConfigured = true
        } else {
            client = nil
            isConfigured = false
        }
    }

    var isSignedIn: Bool {
        currentUserID != nil
    }

    func bootstrap() async {
        guard let client else { return }

        do {
            let session = try await client.auth.session
            applyAuthSession(session)
        } catch {
            currentUserID = nil
            currentUserEmail = nil
        }
    }

    func listenForAuthChanges() async {
        guard let client else { return }

        for await change in client.auth.authStateChanges {
            if let session = change.session {
                applyAuthSession(session)
            } else {
                currentUserID = nil
                currentUserEmail = nil
            }
        }
    }

    func handleDeepLink(_ url: URL) async {
        guard let client else { return }

        do {
            try await client.auth.session(from: url)
            let session = try await client.auth.session
            applyAuthSession(session)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async throws {
        guard let client else {
            throw SupabaseServiceError.notConfigured
        }

        let response = try await client.auth.signUp(
            email: email,
            password: password
        )

        if let session = response.session {
            applyAuthSession(session)
        } else {
            print("✅ Account created. Email confirmation required.")
        }
    }


    func signIn(email: String, password: String) async throws {
        guard let client else {
            throw SupabaseServiceError.notConfigured
        }

        let session = try await client.auth.signIn(
            email: email,
            password: password
        )

        applyAuthSession(session)
    }

    func signOut() async throws {
        guard let client else {
            throw SupabaseServiceError.notConfigured
        }

        try await client.auth.signOut()
        currentUserID = nil
        currentUserEmail = nil
    }

    func syncSession(_ session: Session) async {
        guard let client, let userID = currentUserID else { return }
        print("🔐 Logged in Supabase user:", userID)
        print("📝 Session being uploaded:", session.id)
        
        isSyncing = true
        defer { isSyncing = false }

        do {
            let record = SupabaseSessionRecord(
                id: session.id,
                userId: userID,
                name: session.name,
                sessionNumber: session.sessionNumber,
                mode: session.mode.rawValue,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                isSaved: session.isSaved
            )

            try await client
                .from("sessions")
                .upsert(record)
                .execute()
                print("✅ Session uploaded successfully")

            for clip in session.clips where clip.highlightIndex != nil {
                print("🎬 Uploading clip:", clip.id)
                try await uploadClip(
                    clip,
                    sessionID: session.id,
                    userID: userID,
                    client: client
                )
            }

            lastSyncError = nil
            print("☁️ Synced session \(session.name) to Supabase")
        } catch {
            lastSyncError = error.localizedDescription
            print("❌ Supabase sync failed: \(error.localizedDescription)")
        }
    }

    private func uploadClip(
        _ clip: Clip,
        sessionID: UUID,
        userID: UUID,
        client: SupabaseClient
    ) async throws {
        print("📹 Clip file URL:", clip.fileURL?.path ?? "NO FILE")
        print("⭐ Highlight index:", clip.highlightIndex ?? -1)
        guard !clip.isUploaded else {
            print("⏭️ Clip already uploaded")
            return
        }
        
        guard let fileURL = clip.fileURL else {
            print("❌ Clip has no file URL")
            return
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ Clip file does not exist at:", fileURL.path)
            return
        }
        
        let storagePath = "\(userID.uuidString.lowercased())/\(sessionID.uuidString.lowercased())/\(clip.id.uuidString.lowercased()).mov"
        let fileData = try Data(contentsOf: fileURL)
        
        do {
            try await client.storage
                .from("clips")
                .upload(
                    storagePath,
                    data: fileData,
                    options: FileOptions(contentType: "video/quicktime", upsert: true)
                )
            
            print("✅ Storage upload succeeded")
            
        } catch {
            print("❌ Storage upload failed:", error)
            throw error
        }
        
        let record = SupabaseClipRecord(
            id: clip.id,
            sessionId: sessionID,
            userId: userID,
            triggeredAt: clip.triggeredAt,
            offsetInSession: clip.offsetInSession,
            duration: clip.duration,
            highlightIndex: clip.highlightIndex,
            customTitle: clip.customTitle,
            customName: clip.customName,
            isSecondaryAngle: clip.isSecondaryAngle,
            storagePath: storagePath,
            isUploaded: true
        )
        
        do {
            try await client
                .from("clips")
                .upsert(record)
                .execute()
            
            print("✅ Clips table insert succeeded")
            
        } catch {
            print("❌ Clips table insert failed:", error)
            throw error
        }
    }

    private func applyAuthSession(_ session: Auth.Session) {
        currentUserID = session.user.id
        currentUserEmail = session.user.email
    }
}

enum SupabaseServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Add your project credentials to Secrets.plist."
        }
    }
}

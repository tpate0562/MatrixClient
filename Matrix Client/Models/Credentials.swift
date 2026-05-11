import Foundation

struct Credentials: Codable, Sendable {
    let homeserverURL: URL
    let userId: String
    let deviceId: String
    let accessToken: String
}

struct LoginResponse: Decodable, Sendable {
    let user_id: String
    let access_token: String
    let device_id: String
    let well_known: WellKnown?

    struct WellKnown: Decodable, Sendable {
        let homeserver: Homeserver?
        struct Homeserver: Decodable, Sendable { let base_url: String? }
    }
}

struct WhoamiResponse: Decodable, Sendable {
    let user_id: String
    let device_id: String?
}

struct CreateRoomResponse: Decodable, Sendable { let room_id: String }
struct EventSentResponse: Decodable, Sendable { let event_id: String }
struct UploadResponse: Decodable, Sendable { let content_uri: String }
struct MembersResponse: Decodable, Sendable { let chunk: [JSONValue] }
struct DirectoryResponse: Decodable, Sendable {
    let room_id: String?
    let servers: [String]?
}

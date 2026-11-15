#if canImport(NowPlaying)
import Foundation

struct RemoteQueue: Decodable, Equatable {
    enum State: String, Decodable { case playing, paused, idle }

    struct Item: Decodable, Equatable {
        struct Media: Decodable, Equatable {
            struct Name: Decodable, Equatable { let name: String }
            let name: String?
            let artists: [Name]?
            let album: Name?
            let mediaType: String?
        }

        struct Image: Decodable, Equatable {
            let path: String
            let provider: String
            let remotelyAccessible: Bool?
            let proxyId: String?

            func url(server: URL, size: Int) -> URL? {
                if remotelyAccessible == true, let direct = URL(string: path), direct.scheme == "https" {
                    return direct
                }
                let proxy = server.appendingPathComponent("imageproxy")
                if let proxyId, !proxyId.isEmpty {
                    var url = URLComponents(url: proxy.appendingPathComponent(proxyId), resolvingAgainstBaseURL: false)
                    url?.queryItems = [URLQueryItem(name: "size", value: String(size))]
                    return url?.url
                }
                var url = URLComponents(url: proxy, resolvingAgainstBaseURL: false)
                url?.queryItems = [
                    URLQueryItem(name: "path", value: path),
                    URLQueryItem(name: "provider", value: provider),
                    URLQueryItem(name: "size", value: String(size))
                ]
                return url?.url
            }
        }

        let queueItemId: String
        let name: String?
        let duration: Double?
        let mediaItem: Media?
        let image: Image?
        var title: String? { mediaItem?.name ?? name }
        var artist: String { mediaItem?.artists?.map(\.name).joined(separator: ", ") ?? "" }
        var album: String { mediaItem?.album?.name ?? "" }
        var isRadio: Bool { mediaItem?.mediaType == "radio" }
        var finiteDuration: Double? {
            guard !isRadio, let duration, duration.isFinite, duration > 0 else { return nil }
            return duration
        }
    }

    let queueId: String
    let state: State
    let available: Bool?
    let ended: Bool?
    let items: Int?
    let currentIndex: Int?
    let repeatMode: String?
    let currentItem: Item?
    var elapsedTime: Double?
    var elapsedTimeLastUpdated: Double?
    let playbackSpeed: Double?

    var activeItem: Item? {
        guard state != .idle, available != false, ended != true else { return nil }
        return currentItem
    }

    var canSkipNext: Bool {
        guard let currentIndex else { return false }
        return items.map { currentIndex < $0 - 1 || repeatMode == "all" } ?? true
    }
}

struct RemotePlaybackClient {
    enum Command: String { case play, pause, previous, next, seek }
    enum Failure: Error { case wrongServer, unauthenticated, unavailable, unexpectedResponse, rejected(Int) }

    private struct Greeting: Decodable { let serverId: String }

    private struct Event: Decodable {
        let messageId: String?
        let errorCode: Int?
        let event: String?
        let objectId: String?
    }

    private struct QueueUpdate: Decodable { let data: RemoteQueue }
    private struct TimeUpdate: Decodable { let data: Double }

    let context: RemotePlaybackContext

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func verifyServer() async throws {
        let (data, response) = try await Self.session.data(from: context.serverURL.appendingPathComponent("info"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              try Self.decode(Greeting.self, from: data).serverId == context.serverID
        else { throw Failure.wrongServer }
    }

    func queue(id: String) async throws -> RemoteQueue? {
        let data = try await request("player_queues/get", args: ["queue_id": id])
        return try Self.decode(RemoteQueue?.self, from: data)
    }

    func send(_ command: Command, queueID: String, position: Int? = nil) async throws {
        var args: [String: Any] = ["player_id": queueID]
        args["position"] = position
        _ = try await request("players/cmd/\(command.rawValue)", args: args)
    }

    /// Watches authoritative events while iOS gives the extension execution time.
    /// Reconnects start with a fresh snapshot, so a missed track boundary does not linger.
    func watch(queueID: String, receive: (RemoteQueue?) -> Void) async throws {
        guard var endpoint = URLComponents(
            url: context.serverURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false
        ) else { throw Failure.unavailable }
        endpoint.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        guard let url = endpoint.url else { throw Failure.unavailable }

        // WebSocket lifetime follows the watch task, independently of HTTP timeouts.
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            let greeting = try Self.decode(Greeting.self, from: await Self.read(socket))
            guard greeting.serverId == context.serverID else { throw Failure.wrongServer }
            let authID = UUID().uuidString
            let auth = try Self.commandData("auth", id: authID, args: ["token": context.token])
            try await socket.send(.string(String(decoding: auth, as: UTF8.self)))
            while true {
                let event = try Self.decode(Event.self, from: await Self.read(socket))
                guard event.messageId == authID else { continue }
                guard event.errorCode == nil else { throw Failure.unauthenticated }
                break
            }
            var current = try await queue(id: queueID)
            receive(current)
            while !Task.isCancelled {
                let data = try await Self.read(socket)
                let event = try Self.decode(Event.self, from: data)
                guard event.objectId == queueID else { continue }
                switch event.event {
                case "queue_updated", "queue_items_updated":
                    current = try Self.decode(QueueUpdate.self, from: data).data
                case "queue_time_updated":
                    guard current?.state == .playing else { continue }
                    let position = try Self.decode(TimeUpdate.self, from: data).data
                    // Routine ticks need no metadata write: iOS advances from the
                    // anchor. Keep seek corrections and recovery after reconnect.
                    let elapsed = current?.elapsedTime ?? position
                    let timestamp = current?.elapsedTimeLastUpdated ?? Date().timeIntervalSince1970
                    let projected = elapsed + max(0, Date().timeIntervalSince1970 - timestamp)
                        * (current?.playbackSpeed ?? 1)
                    guard abs(projected - position) > 2 else { continue }
                    current?.elapsedTime = position
                    current?.elapsedTimeLastUpdated = Date().timeIntervalSince1970
                default:
                    continue
                }
                receive(current)
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func request(_ command: String, args: [String: Any]) async throws -> Data {
        var request = URLRequest(url: context.serverURL.appendingPathComponent("api"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.commandData(command, id: UUID().uuidString, args: args)
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        guard (200..<300).contains(http.statusCode) else { throw Failure.rejected(http.statusCode) }
        return data
    }

    private static func commandData(_ command: String, id: String, args: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["command": command, "message_id": id, "args": args])
    }

    private static func read(_ socket: URLSessionWebSocketTask) async throws -> Data {
        switch try await socket.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw Failure.unexpectedResponse
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
#endif

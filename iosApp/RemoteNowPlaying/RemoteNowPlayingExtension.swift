#if canImport(NowPlaying)
import ExtensionFoundation
import Foundation
import ImageIO
import NowPlaying
import Observation
import OSLog

@main
struct RemoteNowPlayingExtension {
    @MainActor static func main() throws {
        if #available(iOS 27.0, *) {
            try MusicAssistantRemoteMediaExtension.main()
        }
    }
}

@available(iOS 27.0, *)
struct MusicAssistantRemoteMediaExtension: RemoteMediaSessionExtension {
    var configuration: RemoteMediaSessionExtensionConfiguration<Self> {
        RemoteMediaSessionExtensionConfiguration(extension: self)
    }

    func session(_ attributes: RemotePlaybackAttributes) async throws -> MusicAssistantRemoteSession {
        let context = try RemotePlaybackContext.load(sessionID: attributes.id)
        let client = RemotePlaybackClient(context: context)
        try await client.verifyServer()
        let queue = try await client.queue(id: attributes.queueID)
        return MusicAssistantRemoteSession(attributes: attributes, queue: queue)
    }
}

@available(iOS 27.0, *)
@MainActor
@Observable
final class MusicAssistantRemoteSession: RemoteMediaSessionRepresentable {
    private(set) var attributes: RemotePlaybackAttributes
    private var queue: RemoteQueue?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicAssistant", category: "RemoteNowPlaying")
    let id: String

    init(attributes: RemotePlaybackAttributes, queue: RemoteQueue?) {
        id = attributes.id
        self.attributes = attributes
        self.queue = queue
        observeQueue()
    }

    deinit { watch?.cancel() }

    func update(_ attributes: RemotePlaybackAttributes) {
        let queueChanged = self.attributes.queueID != attributes.queueID
        self.attributes = attributes
        if queueChanged {
            queue = nil
            observeQueue()
        }
    }

    var content: (any MediaContentRepresentable)? {
        guard let item = queue?.activeItem, let title = item.title else { return nil }
        let artwork = item.image.map { image in
            Artwork(id: image.proxyId ?? "\(image.provider):\(image.path)") { [attributes] size in
                let server = try RemotePlaybackContext.load(sessionID: attributes.id).serverURL
                let dimension = max(size.width, size.height)
                let pixels = Int(min(max(dimension.isFinite ? dimension.rounded(.up) : 1_200, 640), 1_600))
                guard let url = image.url(server: server, size: pixels) else {
                    throw RemotePlaybackClient.Failure.unavailable
                }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cover = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels
                      ] as CFDictionary) else { throw RemotePlaybackClient.Failure.unexpectedResponse }
                return try ArtworkRepresentation(cgImage: cover)
            }
        }
        return MusicContent(
            id: item.queueItemId, songTitle: title, artistName: item.artist, albumName: item.album,
            type: .audio, duration: item.finiteDuration.map { .finite($0) }, artwork: artwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard let queue, queue.activeItem != nil else { return MediaPlaybackSnapshot(state: .stopped) }
        let stamp = queue.elapsedTimeLastUpdated.map(Date.init(timeIntervalSince1970:))
        let rate = Float(queue.playbackSpeed ?? 1)
        return MediaPlaybackSnapshot(
            state: queue.state == .playing ? .playing(rate: rate) : .paused,
            defaultPlaybackRate: rate,
            elapsedTime: queue.elapsedTime,
            timestamp: stamp
        )
    }

    var devices: [MediaDevice] {
        [MediaDevice(id: attributes.queueID, name: attributes.playerName, type: .speaker, capabilities: [])]
    }

    var commands: [MediaCommand] {
        guard let queue, let item = queue.activeItem else { return [] }
        return [
            .play { try await self.send(.play) },
            .pause { try await self.send(.pause) }.enabled(!item.isRadio),
            .next { try await self.send(.next) }.enabled(queue.canSkipNext),
            .previous { try await self.send(.previous) }.enabled((queue.currentIndex ?? 0) > 0),
            .seekToPosition { try await self.send(.seek, position: $0) }.enabled(item.finiteDuration != nil)
        ]
    }

    private func observeQueue() {
        watch?.cancel()
        let attributes = attributes
        watch = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let context = try RemotePlaybackContext.load(sessionID: attributes.id)
                    try await RemotePlaybackClient(context: context).watch(queueID: attributes.queueID) { [weak self] update in
                        guard let self, !Task.isCancelled, self.attributes.queueID == attributes.queueID else { return }
                        if self.queue != update {
                            self.queue = update
                            self.revision += 1
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.queue = nil
                    self?.log.error("Remote playback observation failed (\(type(of: error), privacy: .public), \((error as NSError).code))")
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func send(_ command: RemotePlaybackClient.Command, position: Double? = nil) async throws {
        let attributes = attributes
        let client = try RemotePlaybackClient(context: RemotePlaybackContext.load(sessionID: attributes.id))
        guard let queue, queue.activeItem != nil else { throw RemotePlaybackClient.Failure.unavailable }
        let position = position.flatMap { value in
            guard value.isFinite, let duration = queue.activeItem?.finiteDuration else { return nil as Int? }
            return Int(exactly: min(max(value, 0), duration).rounded(.towardZero))
        }
        if command == .seek, position == nil { throw RemotePlaybackClient.Failure.unavailable }
        let before = revision
        try await client.send(command, queueID: attributes.queueID, position: position)
        // The response can arrive before the queue update. A read-back also covers
        // commands issued when the extension's event connection is reconnecting.
        if let confirmed = try? await client.queue(id: attributes.queueID),
           self.attributes.queueID == attributes.queueID, revision == before {
            self.queue = confirmed
        }
    }
}
#else
@main
enum RemoteNowPlayingExtension {
    static func main() {}
}
#endif

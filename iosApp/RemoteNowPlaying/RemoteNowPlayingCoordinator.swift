#if canImport(NowPlaying)
import ComposeApp
import NowPlaying
import OSLog
import UIKit

@available(iOS 27.0, *)
@MainActor
final class RemoteNowPlayingCoordinator {
    static let shared = RemoteNowPlayingCoordinator()

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicAssistant", category: "RemoteNowPlaying")
    private var subscription: Cancellable?
    private var activationObserver: NSObjectProtocol?
    private var reconciliation: Task<Void, Never>?
    private var revision = 0
    private var desired: RemoteNowPlayingTarget?
    private var current: RemoteMediaSession<RemotePlaybackAttributes>?
    private var published: RemotePlaybackAttributes?
    private var context: RemotePlaybackContext?
    private var needsPrimary = false

    func start() {
        guard subscription == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        subscription = KmpHelper.shared.observeRemoteNowPlaying { [weak self] target, preserve in
            guard let self, !preserve.boolValue else { return }
            desired = target
            reconcile()
        }
    }

    private func reconcile() {
        revision += 1
        guard reconciliation == nil else { return }
        reconciliation = Task {
            var processed: Int
            repeat {
                processed = revision
                do {
                    try await apply(desired)
                } catch {
                    // URL/network errors can include server details. Keep them out of system logs.
                    log.error("Remote Now Playing reconciliation failed (\(type(of: error), privacy: .public), \((error as NSError).code))")
                }
            } while processed != revision
            reconciliation = nil
        }
    }

    private func apply(_ target: RemoteNowPlayingTarget?) async throws {
        guard let target, let url = URL(string: target.serverUrl) else {
            try await endSession()
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        if context?.serverID != target.serverId || context?.serverURL != url || context?.token != target.token {
            try await endSession()
            let newContext = RemotePlaybackContext(
                sessionID: UUID().uuidString, serverURL: url, serverID: target.serverId, token: target.token
            )
            try newContext.save()
            context = newContext
        }
        guard let context else { return }
        let attributes = RemotePlaybackAttributes(
            id: context.sessionID, queueID: target.queueId, playerName: target.playerName
        )
        if let current {
            if published != attributes {
                try await current.update(attributes)
                needsPrimary = true
            }
        } else {
            current = try await RemoteMediaSession.start(attributes: attributes)
            needsPrimary = true
            log.info("Started remote Now Playing session")
        }
        published = attributes
        if needsPrimary, let current, UIApplication.shared.applicationState == .active,
           desired == target {
            try await current.requestToBecomeSystemPrimary()
            needsPrimary = false
            log.info("Requested system Now Playing for remote playback")
        }
    }

    private func endSession() async throws {
        try RemotePlaybackContext.remove()
        if let current {
            try await current.end()
        } else if context == nil {
            for stale in try await RemoteMediaSession<RemotePlaybackAttributes>.sessions() {
                try await stale.end()
            }
        }
        current = nil
        published = nil
        context = nil
        needsPrimary = false
    }
}
#endif

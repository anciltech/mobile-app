#if canImport(NowPlaying)
import Foundation
import XCTest

final class RemotePlaybackClientTests: XCTestCase {
    func testPausedQueueKeepsMetadataAndArtwork() throws {
        let queue = try decodeQueue(state: "paused", index: 0)
        XCTAssertEqual(queue.state, .paused)
        XCTAssertEqual(queue.activeItem?.title, "Track")
        XCTAssertEqual(queue.activeItem?.artist, "Artist")
        XCTAssertEqual(queue.activeItem?.album, "Album")
        XCTAssertEqual(queue.activeItem?.finiteDuration, 240)
        XCTAssertEqual(queue.elapsedTime, 31.25)
        XCTAssertTrue(queue.canSkipNext)

        let server = try XCTUnwrap(URL(string: "https://example.test/music"))
        let artwork = try XCTUnwrap(queue.activeItem?.image?.url(server: server, size: 1_200))
        XCTAssertEqual(artwork.absoluteString, "https://example.test/music/imageproxy/cover-id?size=1200")
    }

    func testIdleOrFinishedQueueDoesNotShowLastTrack() throws {
        XCTAssertNil(try decodeQueue(state: "idle", index: 1).activeItem)
        let ended = try decodeQueue(state: "playing", index: 1, ended: true)
        XCTAssertNil(ended.activeItem)
        XCTAssertFalse(ended.canSkipNext)
        XCTAssertTrue(try decodeQueue(state: "playing", index: 1, repeatMode: "all").canSkipNext)
    }

    private func decodeQueue(
        state: String, index: Int, ended: Bool = false, repeatMode: String = "off"
    ) throws -> RemoteQueue {
        let json = """
        {
            "queue_id": "test-speaker", "state": "\(state)", "available": true,
            "current_index": \(index), "items": 2, "ended": \(ended), "repeat_mode": "\(repeatMode)",
            "elapsed_time": 31.25, "elapsed_time_last_updated": 1773907200,
            "current_item": {
                "queue_item_id": "track-id", "duration": 240,
                "media_item": {
                    "name": "Track", "artists": [{"name": "Artist"}], "album": {"name": "Album"},
                    "media_type": "track"
                },
                "image": {"path": "cover.jpg", "provider": "library", "proxy_id": "cover-id"}
            }
        }
        """
        return try RemotePlaybackClient.decode(RemoteQueue.self, from: Data(json.utf8))
    }
}
#endif

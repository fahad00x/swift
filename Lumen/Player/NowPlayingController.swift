import MediaPlayer
import os
import UIKit

/// Tells the system what the MPV engine is playing (Control Center, the iPhone's Apple TV
/// remote, the lock screen) and runs the commands they send. Created when a session starts
/// and torn down when it ends. The AVPlayer engine doesn't use it: AVKit publishes its own.
@MainActor
final class NowPlayingController {
    private weak var session: PlayerSession?
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    /// `isEnabled` of every command we touched, put back on stop (the center is shared).
    private var savedEnabled: [(command: MPRemoteCommand, enabled: Bool)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var active = false

    init(session: PlayerSession) { self.session = session }

    // MARK: Lifecycle

    func start() {
        guard !active else { return }
        active = true
        registerCommands()
        itemChanged()
    }

    func stop() {
        guard active else { return }
        active = false
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        for target in targets { target.command.removeTarget(target.token) }
        targets = []
        for saved in savedEnabled { saved.command.isEnabled = saved.enabled }
        savedEnabled = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Another episode in the same session: new texts now, its artwork when it arrives.
    func itemChanged() {
        guard active, let session else { return }
        artwork = nil
        update()
        artworkTask?.cancel()
        let key = session.item.ratingKey
        guard let url = session.client.imageURL(session.item.posterPath, width: 600, height: 900) else { return }
        artworkTask = Task { [weak self] in
            let image = await ImageLoader.shared.image(for: url)
            // Late artwork of a previous episode (or of a closed player) is dropped.
            guard !Task.isCancelled, let self, self.active, let image,
                  self.session?.item.ratingKey == key else { return }
            self.artwork = Self.makeArtwork(image)
            self.update()
        }
    }

    /// Publishes the current state. Called on changes only (pause, buffering, seek, duration,
    /// item): the system advances the elapsed time itself from the rate.
    func update() {
        guard active, let session else { return }
        let item = session.item
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: session.position,
            MPNowPlayingInfoPropertyPlaybackRate: session.isPaused || session.isBuffering || session.errorMessage != nil ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if item.isEpisode, let show = item.grandparentTitle {
            info[MPMediaItemPropertyAlbumTitle] = show
            if let season = item.parentIndex, let episode = item.index {
                // Isolated, so «S1 • E3» keeps its order next to an Arabic show name.
                info[MPMediaItemPropertyArtist] = "\(show) – \u{2066}S\(season) • E\(episode)\u{2069}"
            } else {
                info[MPMediaItemPropertyArtist] = show
            }
        }
        if session.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = session.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlaybackSettings.skipSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlaybackSettings.skipSeconds)]

        add(center.playCommand) { session, _ in session.setPaused(false, from: .remote) }
        add(center.pauseCommand) { session, _ in session.setPaused(true, from: .remote) }
        add(center.togglePlayPauseCommand) { session, _ in session.togglePause(from: .remote) }
        add(center.skipForwardCommand) { session, _ in session.skip(by: PlaybackSettings.skipSeconds, from: .remote) }
        add(center.skipBackwardCommand) { session, _ in session.skip(by: -PlaybackSettings.skipSeconds, from: .remote) }
        add(center.changePlaybackPositionCommand) { session, position in
            guard let position else { return false }
            return session.jump(to: position, from: .remote)
        }
        // Episodes come in a later batch.
        for command in [center.nextTrackCommand, center.previousTrackCommand] { setEnabled(command, false) }
    }

    private func setEnabled(_ command: MPRemoteCommand, _ enabled: Bool) {
        savedEnabled.append((command, command.isEnabled))
        command.isEnabled = enabled
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerSession, TimeInterval?) -> Bool) {
        setEnabled(command, true)
        let token = command.addTarget(handler: Self.handler(for: session, action))
        targets.append((command, token))
    }

    /// Not main-actor isolated: the system may call it on any thread.
    private nonisolated static func handler(
        for session: PlayerSession?, _ action: @escaping @MainActor (PlayerSession, TimeInterval?) -> Bool
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak session] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            func run() -> Bool {
                MainActor.assumeIsolated {
                    guard let session else { return false }
                    return action(session, position)
                }
            }
            let done = Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
            return done ? .success : .commandFailed
        }
    }

    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

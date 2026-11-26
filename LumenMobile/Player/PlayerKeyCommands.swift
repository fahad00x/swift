import UIKit

/// iPad (or iPhone) with a keyboard: shortcuts in the player, listed when ⌘ is held.
/// The arrows don't mirror in Arabic: → is forward, as on the keyboard.
extension MobilePlayerViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        func key(_ input: String, _ title: String, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input)
            // Ahead of the system's own use of the key (arrows, space, Esc).
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let seconds = ArabicFormat.digits(Int(PlaybackSettings.skipSeconds))
        return [
            key(" ", "إيقاف / تشغيل", #selector(keyTogglePause)),
            key(UIKeyCommand.inputRightArrow, "تقديم \(seconds) ث", #selector(keyForward)),
            key(UIKeyCommand.inputLeftArrow, "رجوع \(seconds) ث", #selector(keyBack)),
            key(UIKeyCommand.inputUpArrow, "رفع الصوت", #selector(keyVolumeUp)),
            key(UIKeyCommand.inputDownArrow, "خفض الصوت", #selector(keyVolumeDown)),
            key("c", "الترجمة", #selector(keyToggleSubtitles)),
            // The same key on the Arabic keyboard (not listed twice).
            key("ؤ", "", #selector(keyToggleSubtitles)),
            key(UIKeyCommand.inputEscape, "إغلاق", #selector(keyClose)),
        ]
    }

    @objc private func keyTogglePause() {
        session.togglePause()
        session.showControls()
    }

    @objc private func keyForward() { skipByKey(PlaybackSettings.skipSeconds) }
    @objc private func keyBack() { skipByKey(-PlaybackSettings.skipSeconds) }

    private func skipByKey(_ seconds: Double) {
        session.seek(by: seconds)
        session.showControls()
    }

    /// mpv's own volume (0–100 %), on top of the device's.
    @objc private func keyVolumeUp() { session.player.changeVolume(by: 10) }
    @objc private func keyVolumeDown() { session.player.changeVolume(by: -10) }

    /// Off, or back on: the track turned off last, else the profile's language, else the first.
    @objc private func keyToggleSubtitles() {
        let tracks = session.subtitleTracks
        if let on = tracks.first(where: \.isSelected) {
            KeyboardSubtitle.last = on.id
            session.selectSubtitle(nil)
        } else {
            let language = ProfileStore.shared.activeProfile?.preferredSubtitleLanguage ?? "ara"
            let pick = tracks.first { $0.id == KeyboardSubtitle.last }
                ?? tracks.first { StreamPreference.sameLanguage($0.language, language) }
                ?? tracks.first
            guard let pick else { return }
            session.selectSubtitle(pick)
        }
    }

    /// Esc: a panel first, then the player.
    @objc private func keyClose() {
        if session.panel != nil { session.panel = nil; return }
        session.onRequestClose?()
    }
}

/// The subtitle C turned off, to turn it back on.
@MainActor
private enum KeyboardSubtitle {
    static var last: Int?
}

import AVKit
import CoreMedia
import SwiftUI
import UIKit

/// Full-screen MPV player with Infuse-style remote controls:
/// - Click / Play-Pause: pause & resume (or press the skip button when it is shown)
/// - Left / Right: jump 10 s back / forward, swipe on the touch surface to scrub
/// - Down: the four buttons (episodes, subtitles, audio, quality); Left / Right move between
///   them, click opens one's panel; Up hides them
/// - Menu / Back: closes the panel, then the buttons, then the player
final class MPVPlayerViewController: UIViewController {
    let session: PlayerSession
    private let metalLayer: MPVMetalLayer
    private var overlayHost: UIHostingController<PlayerOverlay>!
    private let displayCriteria: AVDisplayCriteria?
    private var scrubBase: Double = 0

    var onDismiss: (() -> Void)?

    init(session: PlayerSession, metalLayer: MPVMetalLayer, displayCriteria: AVDisplayCriteria?) {
        self.session = session
        self.metalLayer = metalLayer
        self.displayCriteria = displayCriteria
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)

        overlayHost = UIHostingController(rootView: PlayerOverlay(session: session))
        overlayHost.view.backgroundColor = .clear
        addChild(overlayHost)
        overlayHost.view.frame = view.bounds
        overlayHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlayHost.view)
        overlayHost.didMove(toParent: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)

        session.onRequestClose = { [weak self] in self?.close() }
        session.onRefocus = { [weak self] in self?.refocus(after: 0.05) }

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        CATransaction.commit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // "Match Content": switch the TV to the video's frame rate and dynamic range (4K HDR / Dolby Vision → HDR10).
        if let manager = view.window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled {
            manager.preferredDisplayCriteria = displayCriteria
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let callback = onDismiss
            onDismiss = nil
            callback?()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        session.isPanelOpen ? [overlayHost] : [self]
    }

    @objc private func didEnterBackground() {
        session.player.isPaused = true
    }

    private func close() {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismiss(animated: true)
    }

    // MARK: Buttons and panels

    private func showButtons() {
        session.buttonsActive = true
        session.showControls(autoHide: false)
        refocus(after: 0.05)
    }

    private func hideButtons() {
        session.panel = nil
        session.buttonsActive = false
        session.showControls()
        refocus(after: 0)
    }

    /// Menu / Back: one step back (the overlay usually takes it first, see PlayerChrome).
    private func stepBack() {
        if session.isPanelOpen { session.stepBack() } else { close() }
    }

    private func refocus(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
    }

    // MARK: Remote input

    /// A keyboard's Escape (simulator, a keyboard paired to the Apple TV) is Menu: handled
    /// here once, instead of the system turning it into a second Menu press.
    private static func type(of press: UIPress) -> UIPress.PressType? {
        if press.key?.keyCode == .keyboardEscape { return .menu }
        return press.type
    }

    private static let handledTypes: Set<UIPress.PressType> = [.select, .playPause, .leftArrow, .rightArrow, .upArrow, .downArrow, .menu]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, let type = Self.type(of: press), Self.handledTypes.contains(type) else {
            // Keyboard arrows / Return: the system turns them into remote presses.
            super.pressesBegan(presses, with: event)
            return
        }

        if session.isPanelOpen {
            switch type {
            case .menu:
                stepBack()
            case .playPause:
                session.togglePause(from: .press)
            case .upArrow where session.panel == nil:
                hideButtons()
            default:
                // Arrows move the focus, click picks (the buttons and panels handle them).
                super.pressesBegan(presses, with: event)
            }
            return
        }

        if session.errorMessage != nil {
            if type == .menu || type == .select { close() }
            return
        }

        switch type {
        case .select:
            if session.skipAction != nil { session.performSkip() } else { session.togglePause(from: .press) }
        case .playPause:
            session.togglePause(from: .press)
        case .leftArrow:
            session.skip(by: -10, from: .press)
        case .rightArrow:
            session.skip(by: 10, from: .press)
        case .downArrow:
            showButtons()
        case .upArrow:
            session.showControls()
        case .menu:
            close()
        default:
            break
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if passesToSystem(presses) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if passesToSystem(presses) { super.pressesCancelled(presses, with: event) }
    }

    /// The end of a press goes on only where its start did: arrows and click while the
    /// buttons or a panel have the focus (they move it), presses the player doesn't use
    /// otherwise. Never Menu: the system would dismiss the player on its own.
    private func passesToSystem(_ presses: Set<UIPress>) -> Bool {
        guard let press = presses.first, let type = Self.type(of: press) else { return true }
        if type == .menu { return false }
        if !Self.handledTypes.contains(type) { return true }
        return session.isPanelOpen && [.upArrow, .downArrow, .leftArrow, .rightArrow, .select].contains(type)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !session.isPanelOpen, session.duration > 0 else { return }
        // A full swipe across the touch surface ≈ 5 minutes (or the whole file if shorter).
        let span = min(session.duration, 300)
        let delta = Double(gesture.translation(in: view).x / max(view.bounds.width, 1)) * span
        switch gesture.state {
        case .began:
            scrubBase = session.position
            session.beginScrub()
        case .changed:
            session.updateScrub(delta: delta)
        case .ended:
            if abs(delta) > 1 { session.commitScrub(base: scrubBase, delta: delta) } else { session.cancelScrub() }
        default:
            session.cancelScrub()
        }
    }
}

// MARK: - Match Content

enum DisplayCriteriaFactory {
    /// Builds criteria from Plex stream info so tvOS switches refresh rate and HDR mode like Infuse.
    static func make(for item: PlexItem) -> AVDisplayCriteria? {
        guard let video = item.videoStream, let fps = video.frameRate, fps > 0 else { return nil }
        let media = item.media.first
        let width = Int32(video.width ?? media?.width ?? 3840)
        let height = Int32(video.height ?? media?.height ?? 2160)

        var extensions: [CFString: Any] = [:]
        switch item.dynamicRangeBadge {
        case "HDR10", "Dolby Vision":
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case "HLG":
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default:
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    codecType: kCMVideoCodecType_HEVC,
                                                    width: width, height: height,
                                                    extensions: extensions as CFDictionary,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { return nil }
        return AVDisplayCriteria(refreshRate: Float(fps), formatDescription: description)
    }
}

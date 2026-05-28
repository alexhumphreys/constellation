import AVFoundation
import AVKit
import SwiftUI
import UIKit

// Video viewer used by AttachmentViewerSheet. Rolls its own controls
// on top of an AVPlayerLayer-backed UIView rather than wrapping
// AVPlayerViewController, because AVKit's transport auto-hides on a
// timer and there's no API to pin it visible — which made every video
// look like a still photo until the user happened to tap. Owning the
// chrome means we keep a play/pause + scrubber + ±10s + ±1 frame row
// always on screen.
//
// Tradeoff: we lose AirPlay / Picture-in-Picture / fullscreen toggle
// that came for free with AVPlayerViewController. Acceptable for a
// local-attachment viewer; reach back for AVPlayerViewController if
// those become asks.

@MainActor
@Observable
final class VideoPlayerController {
    let player: AVPlayer
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isScrubbing: Bool = false

    private var timeObserver: Any?
    private var scrubSeekInFlight: Bool = false
    private var pendingScrubTime: Double?
    private var wasPlayingBeforeScrub: Bool = false

    init(url: URL) {
        player = AVPlayer(url: url)
    }

    func start() {
        // 100ms tick keeps the scrubber smooth without being wasteful;
        // the periodic observer also serves as our "is ready" probe —
        // duration only resolves once the item is loaded, so we read it
        // here rather than via a separate async load.
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // Autoplay on open — matches Photos and means the user isn't
        // staring at a static first frame wondering if it's a video.
        // AVPlayer queues this if the item isn't ready yet.
        player.play()
    }

    func stop() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
    }

    // Scrub lifecycle — capture the prior play state on begin so we
    // can resume playback on release if the user was watching when
    // they grabbed the scrubber. Without this, every drag pauses
    // playback permanently.
    func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        isScrubbing = true
        player.pause()
    }

    func endScrub(at time: Double) {
        isScrubbing = false
        seek(to: time)
        if wasPlayingBeforeScrub {
            player.play()
        }
    }

    func skip(by seconds: Double) {
        seek(to: max(0, min(currentTime + seconds, duration)))
    }

    func seek(to time: Double) {
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // Live scrub seek. Apple's standard pattern (QA1820): one seek in
    // flight at a time, at most one queued — if a new value comes in
    // while a seek is rendering, replace the queued target and let the
    // in-flight one finish. Prevents the slider from outpacing the
    // decoder and ensures every drag position actually paints a frame.
    // Tolerance of 0.1s is coarse enough to be fast on phone hardware
    // while staying within ~3 frames of the requested time.
    func scrubSeek(to time: Double) {
        if scrubSeekInFlight {
            pendingScrubTime = time
            return
        }
        performScrubSeek(to: time)
    }

    private func performScrubSeek(to time: Double) {
        scrubSeekInFlight = true
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(
            to: target,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            // Completion fires on AVFoundation's private queue; hop
            // back to the main actor to touch our @MainActor state.
            Task { @MainActor in
                guard let self else { return }
                self.scrubSeekInFlight = false
                if let pending = self.pendingScrubTime {
                    self.pendingScrubTime = nil
                    self.performScrubSeek(to: pending)
                }
            }
        }
    }

    func stepFrame(by count: Int) {
        guard let item = player.currentItem else { return }
        player.pause()
        item.step(byCount: count)
    }

    // Pulls the frame at the current playhead via AVAssetImageGenerator
    // with zero tolerance so the returned CGImage matches what's on
    // screen exactly (including after a step). Pauses first so the
    // playhead doesn't drift between extraction and the user's intent.
    func currentFrame() async throws -> (image: CGImage, offset: Double) {
        player.pause()
        guard let asset = player.currentItem?.asset else {
            throw VideoFrameError.noAsset
        }
        let time = player.currentTime()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: time)]
            ) { _, image, _, result, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard result == .succeeded, let image else {
                    cont.resume(throwing: VideoFrameError.extractionFailed)
                    return
                }
                cont.resume(returning: image)
            }
        }
        return (image, time.seconds.isFinite ? time.seconds : 0)
    }

    private func tick() {
        if !isScrubbing,
           let t = player.currentItem?.currentTime().seconds,
           t.isFinite {
            currentTime = t
        }
        if let d = player.currentItem?.duration.seconds,
           d.isFinite, d > 0, duration != d {
            duration = d
        }
        isPlaying = player.timeControlStatus == .playing
    }
}

enum VideoFrameError: Error {
    case noAsset
    case extractionFailed
}

struct VideoPlayerView: View {
    @State private var controller: VideoPlayerController
    @State private var isFullscreen: Bool = false
    @State private var saveState: FrameSaveState = .idle

    // Optional handler for saving the displayed frame as a sibling
    // photo attachment. Nil means the save button hides entirely —
    // keeps the player reusable in viewers that don't have an
    // attachment context (e.g. a future preview before import).
    let onSaveFrame: ((image: CGImage, offset: Double)) async throws -> Void

    init(
        url: URL,
        onSaveFrame: @escaping ((image: CGImage, offset: Double)) async throws -> Void
    ) {
        _controller = State(initialValue: VideoPlayerController(url: url))
        self.onSaveFrame = onSaveFrame
    }

    enum FrameSaveState: Equatable {
        case idle
        case saving
        case saved
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: controller.player)
                .ignoresSafeArea(edges: .horizontal)
            controlsBar
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .fullScreenCover(isPresented: $isFullscreen) {
            FullscreenVideo(player: controller.player) {
                isFullscreen = false
            }
        }
    }

    private var controlsBar: some View {
        VStack(spacing: 10) {
            scrubber
            buttonRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.6))
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            timeLabel(controller.currentTime)
                .frame(minWidth: 44, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { newValue in
                        controller.currentTime = newValue
                        // Drive video updates while the finger drags
                        // instead of waiting for release — matches the
                        // iOS Photos / built-in player behaviour.
                        if controller.isScrubbing {
                            controller.scrubSeek(to: newValue)
                        }
                    }
                ),
                // Degenerate range until duration loads — slider stays
                // pinned to 0 for that brief window rather than
                // crashing on 0...0.
                in: 0...max(controller.duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        controller.beginScrub()
                    } else {
                        // Final landing uses zero-tolerance seek so
                        // the frame matches the slider position
                        // exactly; resumes play if we paused for the
                        // scrub.
                        controller.endScrub(at: controller.currentTime)
                    }
                }
            )
            .tint(.white)
            .disabled(controller.duration <= 0)
            timeLabel(controller.duration)
                .frame(minWidth: 44, alignment: .leading)
            controlButton(
                "arrow.up.left.and.arrow.down.right",
                "Full screen",
                size: 18
            ) {
                isFullscreen = true
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 22) {
            FrameStepButton(
                icon: "backward.frame.fill",
                label: "Previous frame"
            ) {
                controller.stepFrame(by: -1)
            }
            controlButton("gobackward.10", "Back 10 seconds") {
                controller.skip(by: -10)
            }
            controlButton(
                controller.isPlaying ? "pause.fill" : "play.fill",
                controller.isPlaying ? "Pause" : "Play",
                size: 30
            ) {
                controller.togglePlay()
            }
            controlButton("goforward.10", "Forward 10 seconds") {
                controller.skip(by: 10)
            }
            FrameStepButton(
                icon: "forward.frame.fill",
                label: "Next frame"
            ) {
                controller.stepFrame(by: 1)
            }
            saveFrameButton
        }
    }

    @ViewBuilder
    private var saveFrameButton: some View {
        let (icon, tint): (String, Color) = {
            switch saveState {
            case .idle:   return ("photo.badge.plus.fill", .white)
            case .saving: return ("photo.badge.plus.fill", .white.opacity(0.4))
            case .saved:  return ("checkmark.circle.fill", .green)
            case .failed: return ("exclamationmark.triangle.fill", .yellow)
            }
        }()
        Button {
            saveCurrentFrame()
        } label: {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                if saveState == .saving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Save current frame as photo")
        .disabled(saveState == .saving)
    }

    private func saveCurrentFrame() {
        Task {
            saveState = .saving
            do {
                let frame = try await controller.currentFrame()
                try await onSaveFrame(frame)
                saveState = .saved
                try? await Task.sleep(for: .milliseconds(1200))
                if saveState == .saved { saveState = .idle }
            } catch {
                saveState = .failed
                try? await Task.sleep(for: .milliseconds(1500))
                if saveState == .failed { saveState = .idle }
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(formatTime(seconds))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
            .monospacedDigit()
    }

    private func controlButton(
        _ icon: String,
        _ label: String,
        size: CGFloat = 22,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(label)
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "—:——" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    // Force-cast is safe: layerClass above guarantees the backing layer.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// Frame-step button that supports press-and-hold to auto-repeat at
// ~2Hz after a short initial delay. Built on a zero-distance
// DragGesture rather than a Button so we can detect the press-down
// and press-up edges cleanly; tap-to-step still works because the
// first onChanged event fires the initial step before any hold
// timer kicks in.
private struct FrameStepButton: View {
    let icon: String
    let label: String
    let onStep: () -> Void

    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding: Bool = false

    // Hold cadence: 500ms before repeats start (so a single tap
    // doesn't accidentally retrigger), then ramp from 500ms down to
    // 250ms over ~5 ticks. The accelerating feel matches how iOS
    // long-press repeat keys behave.
    private static let initialDelay: Duration = .milliseconds(500)
    private static let startInterval: Duration = .milliseconds(500)
    private static let minInterval: Duration = .milliseconds(250)
    private static let intervalStep: Duration = .milliseconds(50)

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 22))
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(isHolding ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isHolding)
            .accessibilityLabel(label)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        onStep()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: Self.initialDelay)
                            var interval = Self.startInterval
                            while !Task.isCancelled {
                                onStep()
                                try? await Task.sleep(for: interval)
                                interval = max(
                                    Self.minInterval,
                                    interval - Self.intervalStep
                                )
                            }
                        }
                    }
                    .onEnded { _ in
                        isHolding = false
                        holdTask?.cancel()
                        holdTask = nil
                    }
            )
            .onDisappear {
                holdTask?.cancel()
                holdTask = nil
            }
    }
}

// Fullscreen cover for the inline player. Reuses the same AVPlayer so
// playhead and play/pause state survive the transition. AVKit's stock
// transport handles orientation, AirPlay, PiP, and a Done button here
// — features we dropped from the inline view to keep the
// always-visible chrome simple.
//
// Swipe-down-to-dismiss runs as a .simultaneousGesture so it coexists
// with AVKit's tap-to-toggle and scrubber drag without stealing
// horizontal interactions.
private struct FullscreenVideo: View {
    let player: AVPlayer
    let onDone: () -> Void

    @State private var dragY: CGFloat = 0

    // Drag past this much vertical distance commits the dismiss. Chosen
    // by feel — short enough to flick away, long enough that a stray
    // downward swipe while reaching for the transport doesn't dismiss.
    private static let dismissThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AVPlayerVCHost(player: player)
                .ignoresSafeArea()
        }
        .offset(y: dragY)
        .statusBarHidden()
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    // Ignore horizontal-dominant drags so AVKit's
                    // scrubber still works without us tugging the view.
                    let dy = value.translation.height
                    let dx = abs(value.translation.width)
                    if dy > 0, dy > dx {
                        dragY = dy
                    }
                }
                .onEnded { value in
                    if value.translation.height > Self.dismissThreshold {
                        onDone()
                    } else {
                        withAnimation(.spring(response: 0.3)) {
                            dragY = 0
                        }
                    }
                }
        )
    }
}

private struct AVPlayerVCHost: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        return vc
    }

    func updateUIViewController(
        _ uiVC: AVPlayerViewController, context: Context
    ) {
        if uiVC.player !== player {
            uiVC.player = player
        }
    }
}

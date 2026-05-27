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

    func stepFrame(by count: Int) {
        guard let item = player.currentItem else { return }
        player.pause()
        item.step(byCount: count)
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

struct VideoPlayerView: View {
    @State private var controller: VideoPlayerController
    @State private var isFullscreen: Bool = false

    init(url: URL) {
        _controller = State(initialValue: VideoPlayerController(url: url))
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
                    set: { controller.currentTime = $0 }
                ),
                // Degenerate range until duration loads — slider stays
                // pinned to 0 for that brief window rather than
                // crashing on 0...0.
                in: 0...max(controller.duration, 0.001),
                onEditingChanged: { editing in
                    controller.isScrubbing = editing
                    if editing {
                        controller.player.pause()
                    } else {
                        controller.seek(to: controller.currentTime)
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
        HStack(spacing: 28) {
            controlButton("backward.frame.fill", "Previous frame") {
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
            controlButton("forward.frame.fill", "Next frame") {
                controller.stepFrame(by: 1)
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

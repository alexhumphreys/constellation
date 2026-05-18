import ConstellationCore
import CryptoKit
import Foundation
import MultipeerConnectivity
import SwiftUI
import UIKit
import os

// Peer-to-peer snapshot sync over MultipeerConnectivity.
//
// Why MC, not iCloud: Apple Personal Team (free tier) can't provision
// the iCloud capability, so the originally-planned iCloud Drive
// snapshot sync wouldn't ship on Alex's own devices. MC needs no
// developer-account capability — just an Info.plist usage string and
// NSBonjourServices entries — and gives genuine peer-to-peer sync
// between two devices on the same WiFi.
//
// Strategy: both devices advertise + browse on service type
// "constln-sync". On lexical-smaller-displayName side, browser invites
// the peer it finds; both sides auto-accept incoming invites. Once an
// MCSession is connected, each side sends its current
// ConstellationSnapshot over reliable MC. Inbound snapshots go through
// the same Store.merge path the AirDrop import uses — same CRDT, same
// idempotence, no schema-version skew possible.
//
// Limitations baked into v1:
// - Both devices must have the app running (foreground, or backgrounded
//   briefly before iOS suspends MC). Edits made while one device is
//   completely off the air get pushed at next meeting.
// - No pairing: anyone on the same WiFi running the app would see and
//   merge with you. Acceptable for a niche personal app on a trusted
//   home network; flagged in project_next_steps as a future polish
//   (per-install pairing token in MCNearbyServiceAdvertiser discovery
//   info).
// - No transport encryption is enforced at the protocol level, but
//   MCSession is created with encryptionPreference: .required which
//   does TLS between peers via auto-negotiated certs.

// MC types are NSObject subclasses that aren't marked Sendable but are
// effectively safe to ferry across actors — Apple's framework already
// passes them between its own queue and ours. Mark them @unchecked
// Sendable here so the delegate methods can hand peer IDs and the
// session reference into a MainActor task without Swift 6 yelling.
extension MCPeerID: @retroactive @unchecked Sendable {}
extension MCSession: @retroactive @unchecked Sendable {}
extension MCNearbyServiceBrowser: @retroactive @unchecked Sendable {}
extension MCNearbyServiceAdvertiser: @retroactive @unchecked Sendable {}

@MainActor
@Observable
final class PeerSync: NSObject {
    enum Status: Equatable, Sendable {
        case off            // user denied local-network permission
        case idle           // not started yet
        case searching      // browsing, no peers found
        case connected(peerCount: Int)
        case synced(at: Date, peerCount: Int)
        case error(String)
    }

    var status: Status = .idle
    // Bumps on every successful inbound merge. RootView watches this
    // via .onChange and rebroadcasts through its own reloadToken so the
    // canvas re-reads the store. Counter, not Bool, so two pulls in
    // quick succession both register.
    var pullCount: Int = 0

    // Service type: 1–15 chars, lowercase + dash. Must match between
    // peers. Bonjour translates this to `_constln-sync._tcp/udp`,
    // which appears in NSBonjourServices in the Info.plist.
    private let serviceType = "constln-sync"
    private static let debounce: Duration = .seconds(2)

    // UIDevice.current.name (e.g. "Alex's iPhone") shows up in the
    // local-network permission prompt and is human-readable in any
    // future peer-list UI. The lexical comparison on displayName is
    // also our tie-breaker for "who invites whom" so identical names
    // would cause both sides to defer forever — UIDevice names are
    // user-set and almost always distinct in practice.
    private let myPeerId = MCPeerID(displayName: UIDevice.current.name)

    // @ObservationIgnored on the implementation guts so SwiftUI
    // doesn't redraw whenever we mutate the MC plumbing — only `status`
    // and `pullCount` participate in observation.
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    // Content hash of the most recent snapshot we sent. Don't resend
    // identical content — saves bandwidth and prevents infinite
    // ping-pong where A sends, B merges, B sends merged, A merges,
    // A sends merged… CRDT guarantees convergence but a tight loop
    // burns battery.
    @ObservationIgnored private var lastSentHash: String?

    // Nonisolated mirror of `session` so the advertiser's invitation
    // handler can read it without a main-actor hop (MC docs ask for
    // the handler to fire synchronously). Mutable stored properties
    // can't use plain `nonisolated` under Swift 6's isolation rules
    // even when the type is Sendable; `nonisolated(unsafe)` is the
    // canonical escape hatch. Writes happen exclusively on the main
    // actor inside start(), so the apparent race is benign.
    @ObservationIgnored nonisolated(unsafe) private var sessionForDelegates: MCSession?

    nonisolated private static let logger = Logger(
        subsystem: "com.constellation.ios", category: "peer-sync"
    )

    override init() {
        super.init()
    }

    // Bootstrap: build the session, start advertising + browsing.
    // Initial sync happens as soon as a peer is found and the inbound
    // snapshot lands; no explicit "pull first" step is needed because
    // the meet-in-the-middle exchange handles both directions.
    func start(store: Store) {
        self.store = store

        let session = MCSession(
            peer: myPeerId,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        self.session = session
        self.sessionForDelegates = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerId, discoveryInfo: nil, serviceType: serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        status = .searching
        Self.logger.info(
            "started peer sync as \(self.myPeerId.displayName, privacy: .public)"
        )
    }

    // Debounced push to currently-connected peers. Called from RootView
    // on every reloadToken bump (every local mutation). Repeated calls
    // collapse to one send. No-op if no peers are connected — when one
    // joins, the connection-state-change handler triggers a fresh send.
    func kick() {
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            await self?.sendSnapshot()
        }
    }

    // MARK: - Send

    private func sendSnapshot() async {
        guard let store, let session else { return }
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        let start = Date()

        do {
            let snapshot = try await store.snapshot()
            let data = try Self.encode(snapshot)
            let hash = Self.contentHash(of: snapshot)
            if hash == lastSentHash {
                // Content unchanged since last successful send — refresh
                // the timestamp so the pill stays current.
                status = .synced(at: Date(), peerCount: peers.count)
                try? await store.emit(WideEvent(
                    op: "peer.snapshot.send",
                    outcome: .skipped,
                    durationMs: Self.ms(since: start),
                    fields: [
                        "peer_count": .int(Int64(peers.count)),
                        "reason": .string("dedupe"),
                    ]
                ))
                return
            }
            try session.send(data, toPeers: peers, with: .reliable)
            lastSentHash = hash
            status = .synced(at: Date(), peerCount: peers.count)
            try? await store.emit(WideEvent(
                op: "peer.snapshot.send",
                outcome: .ok,
                durationMs: Self.ms(since: start),
                fields: [
                    "peer_count": .int(Int64(peers.count)),
                    "bytes": .int(Int64(data.count)),
                    "skills": .int(Int64(snapshot.skills.count)),
                    "areas": .int(Int64(snapshot.areas.count)),
                ]
            ))
        } catch {
            status = .error("send failed: \(error)")
            try? await store.emit(WideEvent(
                op: "peer.snapshot.send",
                outcome: .error,
                durationMs: Self.ms(since: start),
                fields: [
                    "peer_count": .int(Int64(peers.count)),
                    "error": .string(String(describing: error)),
                ]
            ))
        }
    }

    // MARK: - Receive

    private func handleInbound(data: Data, peerCount: Int, peerName: String) async {
        guard let store else { return }
        let start = Date()
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(ConstellationSnapshot.self, from: data)
            let hash = Self.contentHash(of: snapshot)
            // Skip if we already have this exact content — covers the
            // ping-pong case where the peer is echoing back state we
            // already sent.
            if hash == lastSentHash {
                status = .synced(at: Date(), peerCount: peerCount)
                try? await store.emit(WideEvent(
                    op: "peer.snapshot.receive",
                    outcome: .skipped,
                    durationMs: Self.ms(since: start),
                    fields: [
                        "peer_name": .string(peerName),
                        "bytes": .int(Int64(data.count)),
                        "reason": .string("dedupe"),
                    ]
                ))
                return
            }
            try await store.merge(snapshot)
            // Treat the merged state as the new "known cloud state" so
            // a future identical inbound doesn't re-merge. The next push
            // re-snapshots locally and will only fire if our merge
            // produced new content.
            lastSentHash = hash
            status = .synced(at: Date(), peerCount: peerCount)
            pullCount &+= 1
            try? await store.emit(WideEvent(
                op: "peer.snapshot.receive",
                outcome: .ok,
                durationMs: Self.ms(since: start),
                fields: [
                    "peer_name": .string(peerName),
                    "bytes": .int(Int64(data.count)),
                    "skills": .int(Int64(snapshot.skills.count)),
                    "areas": .int(Int64(snapshot.areas.count)),
                ]
            ))
        } catch {
            status = .error("merge failed: \(error)")
            try? await store.emit(WideEvent(
                op: "peer.snapshot.receive",
                outcome: .error,
                durationMs: Self.ms(since: start),
                fields: [
                    "peer_name": .string(peerName),
                    "bytes": .int(Int64(data.count)),
                    "error": .string(String(describing: error)),
                ]
            ))
        }
    }

    // MARK: - Encoding + hashing

    private static func encode(_ snap: ConstellationSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snap)
    }

    // Matches the Store's internal helper so wide-event durations
    // across both subsystems are computed identically (millis since
    // operation start, expressed as Double).
    private static func ms(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000.0
    }

    // Hash the snapshot's *content*, ignoring `generatedAt`. Each call
    // to Store.snapshot() bumps generatedAt to now, so without zeroing
    // it the hash would always differ and the dedupe would never fire.
    private static func contentHash(of snap: ConstellationSnapshot) -> String {
        var copy = snap
        copy.generatedAt = .distantPast
        let data = (try? encode(copy)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - MCSessionDelegate
//
// MC calls delegate methods from a private serial queue, so they're
// inherently nonisolated. Each one bounces to main to touch our state.

extension PeerSync: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        // Capture state + peerCount + name synchronously so the Task
        // closure doesn't capture the (non-Sendable) session ref or
        // peerID directly when an emit needs them.
        let count = session.connectedPeers.count
        let name = peerID.displayName
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.status = .connected(peerCount: count)
                try? await self.store?.emit(WideEvent(
                    op: "peer.connect",
                    outcome: .ok,
                    fields: [
                        "peer_name": .string(name),
                        "peer_count": .int(Int64(count)),
                    ]
                ))
                // Force-resend on connect even if content hasn't
                // changed since last send: a fresh peer hasn't seen
                // our state yet. Clear the dedupe so the send proceeds.
                self.lastSentHash = nil
                await self.sendSnapshot()
            case .connecting:
                break
            case .notConnected:
                if count == 0 {
                    self.status = .searching
                } else {
                    self.status = .connected(peerCount: count)
                }
                try? await self.store?.emit(WideEvent(
                    op: "peer.disconnect",
                    outcome: .ok,
                    fields: [
                        "peer_name": .string(name),
                        "peer_count": .int(Int64(count)),
                    ]
                ))
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        let count = session.connectedPeers.count
        let name = peerID.displayName
        Task { @MainActor [weak self] in
            await self?.handleInbound(data: data, peerCount: count, peerName: name)
        }
    }

    // MC also routes streams + file resources through these callbacks.
    // We only use the data path; satisfy the protocol with empty
    // stubs so the framework doesn't crash trying to call missing
    // methods.

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerSync: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Auto-accept — v1 trusts the local network. The invitation
        // handler ideally fires synchronously; we read sessionForDelegates
        // (a nonisolated mirror set on start()) to avoid an actor hop.
        invitationHandler(true, sessionForDelegates)
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        let desc = String(describing: error)
        Task { @MainActor [weak self] in
            self?.status = .error("advertise failed: \(desc)")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerSync: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        // Lexical tie-break on displayName: only the side with the
        // smaller name initiates the invite. Both sides accept any
        // incoming invite, so if the loser somehow gets there first
        // the connection still happens — this is just to avoid the
        // common case of two simultaneous invites racing.
        let myName = myPeerId.displayName
        let theirName = peerID.displayName
        guard myName < theirName else { return }
        guard let session = sessionForDelegates else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        Self.logger.info("inviting peer \(theirName, privacy: .public)")
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {}

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: any Error
    ) {
        let desc = String(describing: error)
        Task { @MainActor [weak self] in
            self?.status = .error("browse failed: \(desc)")
        }
    }
}

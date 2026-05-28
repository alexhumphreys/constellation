import ConstellationCore
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
// - No transport encryption is enforced at the protocol level, but
//   MCSession is created with encryptionPreference: .required which
//   does TLS between peers via auto-negotiated certs.
//
// Pairing (v2 — current code):
// Each install carries a UUID `pairId` stored in UserDefaults (see
// PeerTrust). The advertiser ships this id in `discoveryInfo["pid"]`
// so the browser side can filter at discovery time; nothing from an
// untrusted install ever crosses the wire. The browser also passes
// its own pid in the invitation context so the advertiser side can
// independently verify trust before accepting — defense in depth, in
// case the discovery-side check is bypassed by an attacker reaching
// the invitation API directly.

// MC types are NSObject subclasses that aren't marked Sendable but are
// effectively safe to ferry across actors — Apple's framework already
// passes them between its own queue and ours. Mark them @unchecked
// Sendable here so the delegate methods can hand peer IDs and the
// session reference into a MainActor task without Swift 6 yelling.
extension MCPeerID: @retroactive @unchecked Sendable {}
extension MCSession: @retroactive @unchecked Sendable {}
extension MCNearbyServiceBrowser: @retroactive @unchecked Sendable {}
extension MCNearbyServiceAdvertiser: @retroactive @unchecked Sendable {}

// Wraps MC's @escaping (Bool, MCSession?) -> Void invitation handler so
// we can ferry it into a MainActor Task. MC fires this exactly once;
// the wrapper is single-use and dies with the surrounding scope.
private struct InvitationResponder: @unchecked Sendable {
    let respond: (Bool, MCSession?) -> Void
}

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
    // Bumps on every successful pair add — used by the showing side's
    // PairSheet to auto-dismiss when the scanning peer claims our QR.
    // Same counter pattern as pullCount.
    var pairCount: Int = 0

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
    @ObservationIgnored private var assets: AssetStore?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    // Hashes we've asked a peer for and haven't received-and-verified
    // yet. ConstellationApp.runAssetGC reads `hasPendingIncomingBlobs`
    // before sweeping so we don't delete bytes that just landed but
    // aren't yet referenced by a merged snapshot row. Cleared on each
    // fresh snapshot merge so a dropped peer can't strand the set
    // forever (next merge cycle re-requests anything still missing).
    @ObservationIgnored private var pendingIncomingBlobs: Set<String> = []
    // Wall-clock timestamp for each outbound BlobRequest, keyed by hash.
    // Read on the matching BlobResponse to compute end-to-end
    // request→bytes-written latency for the receive wide event. With
    // one-at-a-time pacing this holds 0 or 1 entries; dict shape stays
    // forward-compatible if we later allow a small in-flight window.
    @ObservationIgnored private var blobRequestSentAt: [String: Date] = [:]
    // Content hash of the most recent snapshot we sent. Don't resend
    // identical content — saves bandwidth and prevents infinite
    // ping-pong where A sends, B merges, B sends merged, A merges,
    // A sends merged… CRDT guarantees convergence but a tight loop
    // burns battery.
    @ObservationIgnored private var lastSentHash: String?

    // Scan-and-claim pairing state.
    //
    // Show side: when PairSheet's Show tab is up, `inviteToken` holds a
    // freshly-generated one-shot UUID embedded in the QR. An invitation
    // arriving with this token attached is treated as proof that the
    // sender actually saw our QR, and the sender's pid gets added to
    // our trust list right then. Cleared on consumption or PairSheet
    // close — replay-safe because a leaked QR can't be exchanged for
    // trust once the token is gone.
    @ObservationIgnored private var inviteToken: String?
    @ObservationIgnored private var inviteTokenExpiry: Date?

    // Every peerID we've seen via Bonjour, keyed by their pid. Populated
    // even when the trust gate rejects them — scan-and-claim needs to
    // invitePeer on an untrusted peerID once the user scans its QR.
    @ObservationIgnored private var discoveredPeers: [String: MCPeerID] = [:]

    // Scan side: if the user scans a QR before our browser's foundPeer
    // has fired for that peer, we can't invite yet. Stash the claim and
    // complete it from foundPeer.
    @ObservationIgnored private var pendingClaim: PendingClaim?

    private struct PendingClaim {
        let pid: String
        let name: String
        let token: String
        let queuedAt: Date
    }

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
    var hasPendingIncomingBlobs: Bool { !pendingIncomingBlobs.isEmpty }

    func start(store: Store, assets: AssetStore) {
        self.store = store
        self.assets = assets

        let session = MCSession(
            peer: myPeerId,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        self.session = session
        self.sessionForDelegates = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerId,
            discoveryInfo: ["pid": PeerTrust.myPairId],
            serviceType: serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        status = .searching
        Task { [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.sync.start",
                outcome: .ok,
                fields: [
                    "display_name": .string(self?.myPeerId.displayName ?? ""),
                    "trusted_count": .int(Int64(PeerTrust.trustedPeers().count)),
                ]
            ))
        }
    }

    // MARK: - Pairing

    // Show side: generate the one-shot token embedded in our QR. Valid
    // until cleared or until the expiry (5 minutes — long enough for a
    // user to walk between devices, short enough that an abandoned QR
    // photographed off a screen can't be replayed days later).
    func makeInviteToken() -> String {
        let token = UUID().uuidString
        inviteToken = token
        inviteTokenExpiry = Date().addingTimeInterval(300)
        return token
    }

    func clearInviteToken() {
        inviteToken = nil
        inviteTokenExpiry = nil
    }

    // Scan side: the user just scanned a peer's QR. Add the peer to our
    // trust list, then invite that peerID over MC with the token they
    // gave us so the other side knows we're the one who scanned. If we
    // haven't seen the peer via Bonjour yet, stash the claim and let
    // foundPeer complete it when discovery catches up.
    func claimPairing(remotePid: String, remoteName: String, remoteToken: String) {
        // Mirror the add on our side. The remote will add us on theirs
        // when our invitation arrives carrying their token.
        let now = Date()
        let peer = TrustedPeer(
            pairId: remotePid,
            displayName: remoteName.isEmpty ? "Unknown device" : remoteName,
            addedAt: now,
            lastSeen: now
        )
        PeerTrust.add(peer)
        pairCount &+= 1
        Task { [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.pair.add",
                outcome: .ok,
                fields: [
                    "peer_name": .string(peer.displayName),
                    "pid_prefix": .string(String(peer.pairId.prefix(8))),
                    "trusted_count": .int(Int64(PeerTrust.trustedPeers().count)),
                    "via": .string("scan"),
                ]
            ))
        }
        if let peerID = discoveredPeers[remotePid] {
            sendClaimInvitation(to: peerID, token: remoteToken)
        } else {
            pendingClaim = PendingClaim(
                pid: remotePid, name: peer.displayName,
                token: remoteToken, queuedAt: now
            )
            // Force a discovery cycle so foundPeer fires for any already-
            // visible peer matching this pid.
            restartDiscovery()
        }
    }

    private func sendClaimInvitation(to peerID: MCPeerID, token: String) {
        guard let session = sessionForDelegates, let browser else { return }
        guard let ctx = Self.encodeInvitation(
            pid: PeerTrust.myPairId,
            name: myPeerId.displayName,
            token: token
        ) else { return }
        browser.invitePeer(peerID, to: session, withContext: ctx, timeout: 10)
        let name = peerID.displayName
        Task { [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.invitation.sent",
                outcome: .ok,
                fields: [
                    "peer_name": .string(name),
                    "via": .string("claim"),
                ]
            ))
        }
    }

    // Advertiser side: a token-bearing invitation just arrived from an
    // untrusted peer. Verify it matches our currently-advertised token,
    // and if so promote the sender to trust + accept.
    fileprivate func consumeClaim(pid: String, name: String, token: String) -> Bool {
        guard let current = inviteToken,
              token == current,
              let expiry = inviteTokenExpiry,
              Date() < expiry
        else { return false }
        let now = Date()
        let peer = TrustedPeer(
            pairId: pid,
            displayName: name.isEmpty ? "Unknown device" : name,
            addedAt: now,
            lastSeen: now
        )
        PeerTrust.add(peer)
        clearInviteToken()
        pairCount &+= 1
        Task { [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.pair.add",
                outcome: .ok,
                fields: [
                    "peer_name": .string(peer.displayName),
                    "pid_prefix": .string(String(peer.pairId.prefix(8))),
                    "trusted_count": .int(Int64(PeerTrust.trustedPeers().count)),
                    "via": .string("show"),
                ]
            ))
        }
        return true
    }

    // Drop a peer from trust and tear down any current session so we
    // stop pushing snapshots to them. The session is shared across peers,
    // so disconnecting drops every connection — restartDiscovery then
    // re-invites the still-trusted ones. Acceptable churn for an event
    // that fires once per unpair.
    func removePairing(pairId: String) {
        let peers = PeerTrust.trustedPeers()
        let target = peers.first { $0.pairId == pairId }
        PeerTrust.remove(pairId: pairId)
        Task { [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.pair.remove",
                outcome: .ok,
                fields: [
                    "peer_name": .string(target?.displayName ?? ""),
                    "pid_prefix": .string(String(pairId.prefix(8))),
                    "trusted_count": .int(Int64(PeerTrust.trustedPeers().count)),
                ]
            ))
        }
        session?.disconnect()
        restartDiscovery()
    }

    // Cycle the advertiser and browser. The Bonjour service drops + re-
    // publishes (so peers re-discover us with the current discoveryInfo)
    // and our own browser flushes its cached found-peer set (so the next
    // foundPeer callback re-evaluates trust against the latest list).
    func restartDiscovery() {
        guard let advertiser, let browser else { return }
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        if status == .searching || status == .idle {
            // Don't downgrade a connected/synced state — just nudge the
            // pill so the user sees activity if they're watching.
        } else if case .error = status {
            status = .searching
        }
        Task { [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.discovery.restart",
                outcome: .ok,
                fields: [
                    "trusted_count": .int(Int64(PeerTrust.trustedPeers().count)),
                ]
            ))
        }
    }

    // No periodic retry loop. MC's MCNearbyServiceBrowser wraps a
    // CFNetServiceBrowser whose runloop sources don't survive rapid
    // stop/start cycles — sustained restart-on-a-timer eventually trips
    // _CFAssertMismatchedTypeID inside _BrowserCancel and crashes the
    // app. Scan-and-claim already brings both sides into trust in one
    // user action, so periodic retry isn't needed anyway: restart
    // discovery only on user-triggered pair/unpair (and a fresh app
    // launch starts MC clean).

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
            let data = try SyncProtocol.encode(PeerMessage.snapshot(snapshot))
            let hash = SyncProtocol.contentHash(of: snapshot)
            if hash == lastSentHash {
                // Content unchanged since last successful send — refresh
                // the timestamp so the pill stays current.
                status = .synced(at: Date(), peerCount: peers.count)
                try? await store.emit(WideEvent(
                    op: "peer.snapshot.send",
                    outcome: .skipped,
                    durationMs: SyncProtocol.ms(since: start),
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
                durationMs: SyncProtocol.ms(since: start),
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
                durationMs: SyncProtocol.ms(since: start),
                fields: [
                    "peer_count": .int(Int64(peers.count)),
                    "error": .string(String(describing: error)),
                ]
            ))
        }
    }

    // MARK: - Receive

    // Entry point from the MC delegate. Decode the PeerMessage envelope
    // and dispatch by case. Snapshot is the existing CRDT-merge path;
    // blobRequest / blobResponse drive the attachment-bytes phase that
    // runs after metadata merge has matched on both sides.
    private func handleInbound(data: Data, peerCount: Int, peerID: MCPeerID) async {
        guard let store else { return }
        let start = Date()
        let peerName = peerID.displayName
        let msg: PeerMessage
        do {
            msg = try SyncProtocol.decode(data)
        } catch {
            try? await store.emit(WideEvent(
                op: "peer.message.decode",
                outcome: .error,
                durationMs: SyncProtocol.ms(since: start),
                fields: [
                    "peer_name": .string(peerName),
                    "bytes": .int(Int64(data.count)),
                    "error": .string(String(describing: error)),
                ]
            ))
            return
        }
        switch msg {
        case .snapshot(let snap):
            await handleSnapshot(
                snap, fromPeer: peerID, peerCount: peerCount,
                peerName: peerName, bytes: data.count, start: start
            )
        case .blobRequest(let req):
            await handleBlobRequest(
                req, fromPeer: peerID, peerName: peerName, start: start
            )
        case .blobResponse(let resp):
            await handleBlobResponse(
                resp, fromPeer: peerID, peerName: peerName,
                bytes: data.count, start: start
            )
        }
    }

    // MARK: - Snapshot merge

    private func handleSnapshot(
        _ snapshot: ConstellationSnapshot,
        fromPeer peerID: MCPeerID,
        peerCount: Int,
        peerName: String,
        bytes: Int,
        start: Date
    ) async {
        guard let store else { return }
        do {
            let hash = SyncProtocol.contentHash(of: snapshot)
            // Skip the merge if we already have this exact content —
            // covers the ping-pong case where the peer is echoing back
            // state we already sent. BUT still run blob reconciliation
            // below: byte-sync state is independent of snapshot content
            // (peer may have bytes we don't, even when our metadata
            // agrees), and early-returning here used to strand
            // attachments whose metadata was in sync before their bytes
            // had a chance to transfer.
            if hash == lastSentHash {
                status = .synced(at: Date(), peerCount: peerCount)
                try? await store.emit(WideEvent(
                    op: "peer.snapshot.receive",
                    outcome: .skipped,
                    durationMs: SyncProtocol.ms(since: start),
                    fields: [
                        "peer_name": .string(peerName),
                        "bytes": .int(Int64(bytes)),
                        "reason": .string("dedupe"),
                    ]
                ))
                await requestMissingBlobs(fromPeer: peerID, peerName: peerName)
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
                durationMs: SyncProtocol.ms(since: start),
                fields: [
                    "peer_name": .string(peerName),
                    "bytes": .int(Int64(bytes)),
                    "skills": .int(Int64(snapshot.skills.count)),
                    "areas": .int(Int64(snapshot.areas.count)),
                    "attachments": .int(Int64(snapshot.attachments.count)),
                ]
            ))
            // Blob reconciliation phase: any attachment row we just
            // received that references a hash we don't have on disk is a
            // blob the peer should send us. Reset pendingIncomingBlobs
            // on every merge — if a previous transfer dropped mid-way,
            // we re-request now and let MC + the CRDT figure it out.
            await requestMissingBlobs(fromPeer: peerID, peerName: peerName)
        } catch {
            status = .error("merge failed: \(error)")
            try? await store.emit(WideEvent(
                op: "peer.snapshot.receive",
                outcome: .error,
                durationMs: SyncProtocol.ms(since: start),
                fields: [
                    "peer_name": .string(peerName),
                    "bytes": .int(Int64(bytes)),
                    "error": .string(String(describing: error)),
                ]
            ))
        }
    }

    // MARK: - Blob reconciliation

    // Receiver-paced blob pull. Ask for ONE missing hash at a time;
    // re-request from handleBlobResponse after each successful write.
    //
    // Why one-at-a-time: the responder loops `handleBlobRequest` over
    // every hash in the request, loading each file into memory and
    // handing it to MC's send buffer back-to-back. With many fresh
    // videos on the sending device, those base64-bloated payloads stack
    // up in RAM faster than MC drains them and iOS jetsams the app
    // (Alex hit this returning from a week of capturing). Receiver
    // pacing bounds peak memory at ~1 blob × ~1.33 (base64) + MC's
    // single in-flight buffer on both ends — well under the foreground
    // memory limit even for the largest 1080p clips. True chunked
    // transport (MCSession.startStream) is still the planned end state
    // for arbitrarily-large files; this is the bounded interim.
    private func requestMissingBlobs(
        fromPeer peerID: MCPeerID, peerName: String
    ) async {
        guard let store, let assets, let session else { return }
        do {
            let live = try await store.liveContentHashes()
            let onDisk = try await assets.onDiskHashes()
            let needed = live.subtracting(onDisk)
            // Reset pending so a dropped peer or restart can't strand
            // the set forever; next merge cycle re-requests from scratch.
            pendingIncomingBlobs = needed
            guard let next = needed.first else { return }
            blobRequestSentAt[next] = Date()
            let req = PeerMessage.BlobRequest(hashes: [next])
            let data = try SyncProtocol.encode(.blobRequest(req))
            try session.send(data, toPeers: [peerID], with: .reliable)
            try? await store.emit(WideEvent(
                op: "peer.blob.request",
                outcome: .ok,
                fields: [
                    "peer_name": .string(peerName),
                    "hashes_requested": .int(1),
                    "total_pending": .int(Int64(needed.count)),
                ]
            ))
        } catch {
            try? await store.emit(WideEvent(
                op: "peer.blob.request",
                outcome: .error,
                fields: [
                    "peer_name": .string(peerName),
                    "error": .string(String(describing: error)),
                ]
            ))
        }
    }

    // Responder side: the peer asked us for these hashes. Send back
    // every one we have on disk; silently skip the ones we don't (the
    // peer's request will repeat on their next merge cycle if they
    // still need them).
    private func handleBlobRequest(
        _ req: PeerMessage.BlobRequest,
        fromPeer peerID: MCPeerID,
        peerName: String,
        start: Date
    ) async {
        guard let store, let assets, let session else { return }
        var sent = 0
        var skipped = 0
        for hash in req.hashes {
            let blobStart = Date()
            do {
                guard let url = try await assets.url(for: hash) else {
                    skipped += 1
                    continue
                }
                // Mapped read so the file pages in lazily — won't pin
                // the whole video as RSS before JSONEncoder needs it.
                // Base64 encode still materialises a ~1.33× copy, but
                // pairing this with the receiver-paced one-at-a-time
                // request bounds peak memory predictably.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let ext = url.pathExtension
                let resp = PeerMessage.BlobResponse(
                    hash: hash, ext: ext, data: data, sentAt: Date()
                )
                let encoded = try SyncProtocol.encode(.blobResponse(resp))
                try session.send(encoded, toPeers: [peerID], with: .reliable)
                sent += 1
                // dur_ms here covers read + JSON+base64 encode + queueing
                // into MC's send buffer. The actual wire-transit cost
                // ends up on the receiver's peer.blob.receive event as
                // transit_ms, since session.send returns as soon as MC
                // accepts the buffer (not when peers ack).
                try? await store.emit(WideEvent(
                    op: "peer.blob.send",
                    outcome: .ok,
                    durationMs: SyncProtocol.ms(since: blobStart),
                    fields: [
                        "peer_name": .string(peerName),
                        "hash_prefix": .string(String(hash.prefix(12))),
                        "bytes": .int(Int64(data.count)),
                    ]
                ))
            } catch {
                try? await store.emit(WideEvent(
                    op: "peer.blob.send",
                    outcome: .error,
                    durationMs: SyncProtocol.ms(since: blobStart),
                    fields: [
                        "peer_name": .string(peerName),
                        "hash_prefix": .string(String(hash.prefix(12))),
                        "error": .string(String(describing: error)),
                    ]
                ))
            }
        }
        try? await store.emit(WideEvent(
            op: "peer.blob.request.served",
            outcome: .ok,
            durationMs: SyncProtocol.ms(since: start),
            fields: [
                "peer_name": .string(peerName),
                "requested": .int(Int64(req.hashes.count)),
                "sent": .int(Int64(sent)),
                "skipped": .int(Int64(skipped)),
            ]
        ))
    }

    // Receiver side: a blob arrived. Verify the sha256 of the bytes
    // matches the expected hash before writing — without this an
    // adversary (or a bug) could poison the on-disk store with the
    // wrong bytes under a trusted hash. Drop on mismatch.
    private func handleBlobResponse(
        _ resp: PeerMessage.BlobResponse,
        fromPeer peerID: MCPeerID,
        peerName: String,
        bytes: Int,
        start: Date
    ) async {
        guard let store, let assets else { return }
        // Two timing breadcrumbs alongside the receive-processing dur_ms:
        //   - request_to_receive_ms: from our outbound BlobRequest to
        //     the moment MC handed us the response bytes. Round-trip,
        //     dominated by the sender's encode + MC's wire transit.
        //   - transit_ms: from the sender's pre-send stamp to our
        //     arrival anchor. Strips sender-side encode cost from
        //     request_to_receive_ms, leaving the wire portion.
        // Both optional (back-compat with older builds that didn't
        // stamp / didn't track) and clock-skew-tolerant for transit_ms
        // since two devices on the same WiFi typically NTP within ms.
        let requestSentAt = blobRequestSentAt.removeValue(forKey: resp.hash)
        let requestToReceiveMs: Double? = requestSentAt.map {
            start.timeIntervalSince($0) * 1000.0
        }
        let transitMs: Double? = resp.sentAt.map {
            start.timeIntervalSince($0) * 1000.0
        }
        let computed = AssetStore.sha256Hex(resp.data)
        guard computed == resp.hash else {
            var fields: [String: WideValue] = [
                "peer_name": .string(peerName),
                "hash_prefix": .string(String(resp.hash.prefix(12))),
                "bytes": .int(Int64(resp.data.count)),
                "reason": .string("hash_mismatch"),
            ]
            if let requestToReceiveMs {
                fields["request_to_receive_ms"] = .double(requestToReceiveMs)
            }
            if let transitMs { fields["transit_ms"] = .double(transitMs) }
            try? await store.emit(WideEvent(
                op: "peer.blob.receive",
                outcome: .error,
                durationMs: SyncProtocol.ms(since: start),
                fields: fields
            ))
            return
        }
        do {
            _ = try await assets.write(resp.data, fileExtension: resp.ext)
            // Thumbnails are local-cache, never synced (per attachment
            // design memo) — the receiving device generates its own from
            // the freshly-arrived canonical bytes. Failure here doesn't
            // poison the receive; the grid falls back to its missing-
            // thumb glyph until next time.
            let importer = AttachmentImporter(assets: assets, store: store)
            do {
                try await importer.regenerateThumbnail(
                    forHash: resp.hash, ext: resp.ext
                )
            } catch {
                try? await store.emit(WideEvent(
                    op: "peer.blob.thumb",
                    outcome: .error,
                    fields: [
                        "hash_prefix": .string(String(resp.hash.prefix(12))),
                        "error": .string(String(describing: error)),
                    ]
                ))
            }
            pendingIncomingBlobs.remove(resp.hash)
            var fields: [String: WideValue] = [
                "peer_name": .string(peerName),
                "hash_prefix": .string(String(resp.hash.prefix(12))),
                "bytes": .int(Int64(resp.data.count)),
                "remaining": .int(Int64(pendingIncomingBlobs.count)),
            ]
            if let requestToReceiveMs {
                fields["request_to_receive_ms"] = .double(requestToReceiveMs)
            }
            if let transitMs { fields["transit_ms"] = .double(transitMs) }
            try? await store.emit(WideEvent(
                op: "peer.blob.receive",
                outcome: .ok,
                durationMs: SyncProtocol.ms(since: start),
                fields: fields
            ))
            // Bump pullCount so any UI listening on inbound changes
            // (the attachments grid in SkillDetailView, future hooks)
            // re-renders once the bytes land. Cheap signal — the grid
            // will reload from the store + assets folder.
            pullCount &+= 1
            // Pull the next missing blob, if any. This is the pacing
            // loop: one blob requested → one written → request next.
            // Receiver-paced backpressure keeps the responder's send
            // buffer and our own decode buffer bounded at one payload.
            await requestMissingBlobs(fromPeer: peerID, peerName: peerName)
        } catch {
            var fields: [String: WideValue] = [
                "peer_name": .string(peerName),
                "hash_prefix": .string(String(resp.hash.prefix(12))),
                "bytes": .int(Int64(resp.data.count)),
                "reason": .string("write_error"),
                "error": .string(String(describing: error)),
            ]
            if let requestToReceiveMs {
                fields["request_to_receive_ms"] = .double(requestToReceiveMs)
            }
            if let transitMs { fields["transit_ms"] = .double(transitMs) }
            try? await store.emit(WideEvent(
                op: "peer.blob.receive",
                outcome: .error,
                durationMs: SyncProtocol.ms(since: start),
                fields: fields
            ))
        }
    }

    // MARK: - Invitation context

    // Sent as `withContext:` on every browser → advertiser invitation.
    // Two acceptance paths on the advertiser side:
    //   1. `pid` is in our trust list (post-pairing reconnect — the
    //      common case).
    //   2. `token` matches our currently-advertised inviteToken (the
    //      scan-and-claim path: the sender just scanned our QR and is
    //      proving it by echoing our one-shot token). On accept, we
    //      add `pid` to our trust list and consume the token.
    //
    // v=1: pid only (legacy; rejected by v=2 receivers because token
    //      is missing and pid is unknown until paired).
    // v=2: pid + name + optional token.
    private struct InvitationContext: Codable {
        var v: Int
        var pid: String
        var name: String?
        var token: String?
    }

    nonisolated private static func encodeInvitation(
        pid: String, name: String? = nil, token: String? = nil
    ) -> Data? {
        let ctx = InvitationContext(v: 2, pid: pid, name: name, token: token)
        return try? JSONEncoder().encode(ctx)
    }

    nonisolated private static func decodeInvitation(_ data: Data?) -> InvitationContext? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(InvitationContext.self, from: data)
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
        Task { @MainActor [weak self] in
            await self?.handleInbound(data: data, peerCount: count, peerID: peerID)
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
        // Two accept paths:
        //   1. Sender's pid is already in our trust list (the common
        //      post-pairing reconnect case).
        //   2. Sender's invitation carries a token matching our current
        //      one-shot inviteToken (the scan-and-claim path; sender
        //      proves they saw our QR by echoing the token, and we
        //      promote them to trust right here).
        // Anything else gets rejected at the discovery layer's belt-
        // and-braces sibling — nothing untrusted opens a session.
        guard let ctx = Self.decodeInvitation(context) else {
            invitationHandler(false, nil)
            return
        }
        let displayName = peerID.displayName

        if PeerTrust.isTrusted(ctx.pid) {
            let pid = ctx.pid
            Task.detached(priority: .background) {
                PeerTrust.updateLastSeen(pairId: pid, displayName: displayName)
            }
            invitationHandler(true, sessionForDelegates)
            return
        }

        if let token = ctx.token {
            let pid = ctx.pid
            let name = ctx.name ?? displayName
            let sessionRef = sessionForDelegates
            // MC's invitation handler is a plain (non-Sendable) closure;
            // Swift 6 strict concurrency won't let us send it into a
            // Task. Wrap once, mark @unchecked Sendable — MC itself is
            // single-shot on this handler so the wrap is benign.
            let responder = InvitationResponder(respond: invitationHandler)
            Task { @MainActor [weak self] in
                guard let self else {
                    responder.respond(false, nil)
                    return
                }
                if self.consumeClaim(pid: pid, name: name, token: token) {
                    responder.respond(true, sessionRef)
                } else {
                    responder.respond(false, nil)
                    try? await self.store?.emit(WideEvent(
                        op: "peer.invitation.rejected",
                        outcome: .skipped,
                        fields: [
                            "peer_name": .string(displayName),
                            "pid_prefix": .string(String(pid.prefix(8))),
                            "reason": .string("bad_token"),
                        ]
                    ))
                }
            }
            return
        }

        // Neither path: reject and log.
        let remotePidPrefix = String(ctx.pid.prefix(8))
        invitationHandler(false, nil)
        Task { @MainActor [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.invitation.rejected",
                outcome: .skipped,
                fields: [
                    "peer_name": .string(displayName),
                    "pid_prefix": .string(remotePidPrefix),
                    "reason": .string("untrusted"),
                ]
            ))
        }
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
        // Trust gate: every advertiser ships its pair id in
        // discoveryInfo["pid"]. Discard peers whose pid isn't in our
        // trusted list — nothing reaches the invite/session layer for
        // strangers on the same WiFi.
        let theirPid = info?["pid"] ?? ""
        // Cache every peerID we've seen, trusted or not — scan-and-claim
        // needs to invitePeer on a not-yet-trusted MCPeerID once the
        // user scans its QR.
        if !theirPid.isEmpty {
            let captured = peerID
            let pid = theirPid
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveredPeers[pid] = captured
                // If the user already scanned this pid's QR and we were
                // waiting on discovery, complete the claim now.
                if let claim = self.pendingClaim, claim.pid == pid {
                    self.pendingClaim = nil
                    self.sendClaimInvitation(to: captured, token: claim.token)
                }
            }
        }
        guard PeerTrust.isTrusted(theirPid) else {
            let name = peerID.displayName
            let pidPrefix = String(theirPid.prefix(8))
            Task { @MainActor [weak self] in
                try? await self?.store?.emit(WideEvent(
                    op: "peer.discovery.skipped",
                    outcome: .skipped,
                    fields: [
                        "peer_name": .string(name),
                        "pid_prefix": .string(pidPrefix),
                        "reason": .string("untrusted"),
                    ]
                ))
            }
            return
        }
        // Lexical tie-break on displayName: only the side with the
        // smaller name initiates the invite. Both sides accept any
        // incoming invite, so if the loser somehow gets there first
        // the connection still happens — this is just to avoid the
        // common case of two simultaneous invites racing.
        let myName = myPeerId.displayName
        let theirName = peerID.displayName
        guard myName < theirName else { return }
        guard let session = sessionForDelegates else { return }
        // Skip if we're already connected to this peer — restartDiscovery
        // cycles the browser, which re-fires foundPeer for peers still
        // in our session. A second invite during a live session can lead
        // MC to tear down and rebuild the connection unnecessarily.
        guard !session.connectedPeers.contains(peerID) else { return }
        guard let ctx = Self.encodeInvitation(pid: PeerTrust.myPairId) else { return }
        let pid = theirPid
        Task.detached(priority: .background) {
            PeerTrust.updateLastSeen(pairId: pid, displayName: theirName)
        }
        browser.invitePeer(peerID, to: session, withContext: ctx, timeout: 10)
        let peerName = theirName
        let peerPid = pid
        Task { @MainActor [weak self] in
            try? await self?.store?.emit(WideEvent(
                op: "peer.invitation.sent",
                outcome: .ok,
                fields: [
                    "peer_name": .string(peerName),
                    "pid_prefix": .string(String(peerPid.prefix(8))),
                ]
            ))
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        // Clean up our discoveredPeers cache so a future claim doesn't
        // try to invite a stale peerID. MCPeerID equality is by
        // displayName, which is stable for the lifetime of the session.
        let lost = peerID
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let pid = self.discoveredPeers.first(where: { $0.value == lost })?.key {
                self.discoveredPeers.removeValue(forKey: pid)
            }
        }
    }

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

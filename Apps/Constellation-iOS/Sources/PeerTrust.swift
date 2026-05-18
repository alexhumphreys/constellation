import Foundation
import os

// Per-install pairing identity and the set of peers we trust to merge
// with us over MultipeerConnectivity.
//
// Why a separate trust layer (instead of "anyone on the WiFi"): a v1
// snapshot from a stranger merges wholesale via LWW into our store —
// silently. The fix is per-install UUIDs exchanged out-of-band via QR
// codes, then carried in `MCNearbyServiceAdvertiser.discoveryInfo` so
// untrusted peers are filtered at the discovery layer before any data
// crosses the wire.
//
// Stored in UserDefaults rather than the CRDT store on purpose: trust
// decisions are device-local. If trust rode the CRDT layer, pairing
// device A with B would auto-propagate to C the next time A and C
// sync, defeating the point.
enum PeerTrust {
    // Single key per install. Generated lazily on first read so a fresh
    // install + delete-uninstall-reinstall yields a new pair id (this is
    // a feature: a reinstalled app has to re-pair, since the old install
    // could be in someone else's hands).
    private static let myPairIdKey = "constellation.pair.myPairId"
    private static let trustedPeersKey = "constellation.pair.trusted"

    private static let logger = Logger(
        subsystem: "com.constellation.ios", category: "peer-trust"
    )

    // The lock guards the trusted-peers list against concurrent mutation
    // (e.g. main-thread UI update racing with MC delegate's lastSeen
    // bump). UserDefaults itself is thread-safe, but the read-modify-
    // write of a Codable array isn't atomic without external coordination.
    private static let lock = NSLock()

    // MARK: - Self identity

    static var myPairId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: myPairIdKey) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: myPairIdKey)
        logger.info("generated install pair id")
        return fresh
    }

    // MARK: - Trusted peers

    static func trustedPeers() -> [TrustedPeer] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    static func isTrusted(_ pairId: String?) -> Bool {
        guard let pairId, !pairId.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().contains { $0.pairId == pairId }
    }

    static func add(_ peer: TrustedPeer) {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadLocked()
        // De-dupe: replace the existing entry if this pair id is already
        // present (their displayName or lastSeen may have changed since).
        peers.removeAll { $0.pairId == peer.pairId }
        peers.append(peer)
        saveLocked(peers)
    }

    static func remove(pairId: String) {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadLocked()
        peers.removeAll { $0.pairId == pairId }
        saveLocked(peers)
    }

    static func updateLastSeen(pairId: String, displayName: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadLocked()
        guard let idx = peers.firstIndex(where: { $0.pairId == pairId }) else { return }
        peers[idx].lastSeen = Date()
        if let displayName, !displayName.isEmpty {
            peers[idx].displayName = displayName
        }
        saveLocked(peers)
    }

    // MARK: - Persistence (lock-held)

    private static func loadLocked() -> [TrustedPeer] {
        guard let data = UserDefaults.standard.data(forKey: trustedPeersKey) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrustedPeer].self, from: data)) ?? []
    }

    private static func saveLocked(_ peers: [TrustedPeer]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(peers) else { return }
        UserDefaults.standard.set(data, forKey: trustedPeersKey)
    }
}

struct TrustedPeer: Codable, Sendable, Identifiable, Equatable {
    var pairId: String
    var displayName: String
    var addedAt: Date
    var lastSeen: Date

    var id: String { pairId }
}

import ConstellationCore
import CryptoKit
import Foundation

// Wire protocol for peer-to-peer snapshot sync — transport-generic. The
// types and helpers here describe *what* crosses the wire, not how. If a
// cloud transport (iCloud / HTTP / S3) ever lands, this file is the bit
// that would lift into a shared sync package; the MC plumbing in
// PeerSync.swift stays app-side.

// Single Codable envelope for every sync message. Discriminator is
// Swift's auto-generated enum-case key, so a snapshot serialises as
// `{"snapshot": {...}}`, a blob request as
// `{"blobRequest": {"hashes": [...]}}`, etc.
//
// v1 deliberately uses a single `Data` per blob (base64-encoded inside
// the JSON envelope). Adequate for the typical 1080p clip (~2-15MB
// after re-encode); see project_next_steps for the OutputStream-chunked
// end state planned when video sizes grow.
enum PeerMessage: Codable, Sendable {
    case snapshot(ConstellationSnapshot)
    case blobRequest(BlobRequest)
    case blobResponse(BlobResponse)

    struct BlobRequest: Codable, Sendable {
        var hashes: [String]
    }

    struct BlobResponse: Codable, Sendable {
        var hash: String
        // Extension is the source of truth for how to name the file on
        // disk — sender derives from the existing assets/<hash>.<ext>
        // entry. We don't carry mimeType because the Attachment row
        // already has it; the asset file just needs a stable name.
        var ext: String
        var data: Data
        // Sender wall-clock taken just before the transport hand-off.
        // Receiver subtracts from its arrival time to derive wire
        // transit (encompasses the transport's queue + transmission).
        // Optional so older builds without this field still decode.
        var sentAt: Date?
    }
}

enum SyncProtocol {
    static func encode(_ msg: PeerMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(msg)
    }

    static func decode(_ data: Data) throws -> PeerMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PeerMessage.self, from: data)
    }

    static func encode(_ snap: ConstellationSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snap)
    }

    // Hash the snapshot's *content*, ignoring `generatedAt`. Each call
    // to Store.snapshot() bumps generatedAt to now, so without zeroing
    // it the hash would always differ and the dedupe would never fire.
    static func contentHash(of snap: ConstellationSnapshot) -> String {
        var copy = snap
        copy.generatedAt = .distantPast
        let data = (try? encode(copy)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // Matches the Store's internal helper so wide-event durations
    // across both subsystems are computed identically (millis since
    // operation start, expressed as Double).
    static func ms(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000.0
    }
}

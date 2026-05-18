import SwiftUI
import UIKit

// "Sync" settings sheet, reached by tapping the sync pill. Lists every
// trusted peer, lets the user unpair any of them, and surfaces the
// "Pair new device" CTA.
//
// Why this UI is load-bearing: paired-only sync is a hard cutover from
// v1's auto-accept-everyone behavior. After upgrade, existing users see
// "no trusted devices" and have to re-pair via QR. The sheet is where
// that flow lives, so the empty state has to read as a clear call to
// action — not as a bug.
struct SyncSheet: View {
    let peerSync: PeerSync
    let onClose: () -> Void

    @State private var peers: [TrustedPeer] = []
    @State private var showPair: Bool = false
    @State private var unpairTarget: TrustedPeer? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showPair = true
                    } label: {
                        Label("Pair new device", systemImage: "qrcode.viewfinder")
                            .foregroundStyle(.white)
                    }
                } header: {
                    Text("Add a device")
                } footer: {
                    Text(
                        "Both devices need to scan each other's pairing code. "
                        + "Sync only works between paired devices."
                    )
                    .font(.caption2)
                }

                Section {
                    if peers.isEmpty {
                        Text("No paired devices yet.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        ForEach(peers) { peer in
                            peerRow(peer)
                        }
                    }
                } header: {
                    Text("Paired devices")
                }

                Section {
                    LabeledContent("This device") {
                        Text(UIDevice.current.name)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    LabeledContent("Pair ID") {
                        Text(PeerTrust.myPairId.prefix(8) + "…")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } header: {
                    Text("About")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Sky.bg2)
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { reload() }
        .sheet(isPresented: $showPair, onDismiss: { reload() }) {
            PairSheet(
                peerSync: peerSync,
                onClose: { showPair = false }
            )
        }
        .confirmationDialog(
            unpairTitle,
            isPresented: Binding(
                get: { unpairTarget != nil },
                set: { if !$0 { unpairTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                if let t = unpairTarget {
                    peerSync.removePairing(pairId: t.pairId)
                    unpairTarget = nil
                    reload()
                }
            }
            Button("Cancel", role: .cancel) { unpairTarget = nil }
        } message: {
            Text("This device will no longer sync with \(unpairTarget?.displayName ?? "this peer").")
        }
    }

    private var unpairTitle: String {
        "Unpair \(unpairTarget?.displayName ?? "device")?"
    }

    private func peerRow(_ peer: TrustedPeer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .foregroundStyle(.white)
                Text("Last seen \(Self.relative(peer.lastSeen))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button(role: .destructive) {
                unpairTarget = peer
            } label: {
                Text("Unpair")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private func reload() {
        peers = PeerTrust.trustedPeers().sorted { $0.addedAt > $1.addedAt }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

//
//  SPECTRE Capture — deposit status screen (mandate §3.1 minimal UI):
//  Filmer · En attente · Transfert en cours · Transfert confirmé · Erreur / à réessayer.
//  Honest by design: anything not confirmed is still on this phone.
//

import SwiftUI
import UIKit
#if canImport(SpectreCore)
import SpectreCore
#endif

struct SpectreStatusView: View {
    @ObservedObject var service: SpectreDepositService
    var onFilm: (() -> Void)?
    @State private var showEnrollment = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    if !service.isEnrolled {
                        Button("Configurer cet appareil (invitation)") { showEnrollment = true }
                            .accessibilityIdentifier("spectre.enroll")
                    }
                    if let onFilm {
                        Button(action: onFilm) { Label("Filmer", systemImage: "video.fill") }
                            .accessibilityIdentifier("spectre.film")
                    }
                } footer: {
                    Text("Une vidéo non confirmée est encore sur ce téléphone. iOS peut retarder l'envoi en arrière-plan ; ouvrez l'application pour le relancer. Cette application ne donne aucun accès au Drive.")
                }
                Section("Vidéos") {
                    if service.records.isEmpty { Text("Aucune vidéo en attente").foregroundColor(.secondary) }
                    ForEach(service.records, id: \.captureId) { r in
                        SpectreRecordRow(record: r) { service.retry(r.captureId) }
                    }
                }
            }
            .navigationTitle("SPECTRE Capture")
            .sheet(isPresented: $showEnrollment) { SpectreEnrollmentView(service: service) }
        }
        .navigationViewStyle(.stack)
    }
}

struct SpectreRecordRow: View {
    let record: CaptureRecord
    let retry: () -> Void

    var body: some View {
        let status = record.userFacingStatus
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon(status)).foregroundColor(color(status))
                Text(record.createdAt, style: .time).font(.headline)
                Spacer()
                if let size = record.fingerprint?.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption).foregroundColor(.secondary)
                }
            }
            Text(status.labelFR).font(.subheadline).accessibilityIdentifier("spectre.status")
            if case .transferring(let p) = status { ProgressView(value: p) }
            if needsManualRetry(status) {
                Button(isBlocked(status) ? "Renvoyer une nouvelle copie" : "Réessayer", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func needsManualRetry(_ s: UserFacingStatus) -> Bool {
        switch s {
        case .blocked: return true
        case .error(let retryable, _): return !retryable || record.failure?.nextAttemptAt == nil
        default: return false
        }
    }
    private func isBlocked(_ s: UserFacingStatus) -> Bool { if case .blocked = s { return true }; return false }
    private func icon(_ s: UserFacingStatus) -> String {
        switch s {
        case .pending: return "clock"
        case .transferring: return "arrow.up.circle"
        case .verifying: return "checkmark.shield"
        case .confirmedLocalCopyRemains: return "exclamationmark.circle"
        case .confirmed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle"
        case .blocked: return "xmark.octagon.fill"
        }
    }
    private func color(_ s: UserFacingStatus) -> Color {
        switch s {
        case .confirmed: return .green
        case .blocked, .error: return .red
        case .confirmedLocalCopyRemains: return .orange
        default: return .accentColor
        }
    }
}

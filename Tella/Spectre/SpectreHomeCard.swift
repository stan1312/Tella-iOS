//
//  SPECTRE Capture — compact entry point on Tella's home screen.
//

import SwiftUI
#if canImport(SpectreCore)
import SpectreCore
#endif

struct SpectreHomeCard: View {
    @ObservedObject var service: SpectreDepositService
    @State private var open = false

    private var pendingCount: Int { service.records.filter { $0.stage != .completed }.count }
    private var problemCount: Int { service.records.filter { $0.stage == .blocked || ($0.failure != nil && $0.failure?.nextAttemptAt == nil) }.count }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                Image(systemName: problemCount > 0 ? "exclamationmark.triangle.fill" : "icloud.and.arrow.up")
                    .foregroundColor(problemCount > 0 ? .red : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DÉPÔT SPECTRE").font(.custom(Styles.Fonts.boldFontName, size: 13)).kerning(1.2).foregroundColor(.white)
                    Text(summary).font(.system(size: 12, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.6))
            }
            .padding()
            .background(Color.black)
            .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
            .padding(.horizontal, 16)
        }
        .accessibilityIdentifier("spectre.homecard")
        .sheet(isPresented: $open) { SpectreStatusView(service: service) }
    }

    private var summary: String {
        if !service.isEnrolled { return "Appareil non configuré : scannez votre invitation" }
        if problemCount > 0 { return "\(problemCount) vidéo(s) à vérifier — encore sur ce téléphone" }
        if pendingCount > 0 { return "\(pendingCount) vidéo(s) en attente ou en cours d'envoi" }
        return "Aucune vidéo en attente"
    }
}

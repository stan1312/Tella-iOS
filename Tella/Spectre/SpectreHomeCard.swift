//
//  SPECTRE Capture — home screen: deposit card + the two capture buttons
//  (camera, dictaphone) whose recordings go to the deposit.
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
                    Text(title).font(.custom(Styles.Fonts.boldFontName, size: 13)).kerning(1.2).foregroundColor(.white)
                        .lineLimit(1).truncationMode(.tail)
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
        .onAppear { service.refreshDepositStatus() }
        .sheet(isPresented: $open) { SpectreStatusView(service: service) }
    }

    /// "DÉPÔT · <demonstration of the day>" when the owner activated one.
    private var title: String {
        guard service.isEnrolled, let name = service.depositName, !name.isEmpty else { return "DÉPÔT SPECTRE" }
        return service.depositIsEvent ? "DÉPÔT · \(name.uppercased())" : "DÉPÔT · DOSSIER PRINCIPAL"
    }

    private var summary: String {
        if !service.isEnrolled { return "Appareil non configuré : scannez votre invitation" }
        if problemCount > 0 { return "\(problemCount) vidéo(s) à vérifier — encore sur ce téléphone" }
        if pendingCount > 0 { return "\(pendingCount) vidéo(s) en attente ou en cours d'envoi" }
        return "Aucune vidéo en attente"
    }
}


struct SpectreCaptureButtons: View {
    @ObservedObject var mainAppModel: MainAppModel

    var body: some View {
        HStack(spacing: 12) {
            tile(title: "APPAREIL PHOTO", symbol: "video", id: "spectre.home.camera") {
                mainAppModel.changeTab(to: .camera)
            }
            tile(title: "DICTAPHONE", symbol: "mic", id: "spectre.home.mic") {
                mainAppModel.changeTab(to: .mic)
            }
        }
        .padding(.horizontal, 16)
    }

    private func tile(title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.white)
                Spacer()
                Text(title)
                    .font(.custom(Styles.Fonts.boldFontName, size: 13))
                    .kerning(1.2)
                    .foregroundColor(.white)
                Text("→ dépôt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.black)
            .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

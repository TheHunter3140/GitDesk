import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// Fond doux commun à tous les écrans principaux.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.0)],
                           startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// Surface « verre » : Liquid Glass quand le SDK et l'iOS le permettent, matériau translucide sinon.
struct GlassCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ c: Content) -> some View {
        c.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

extension View {
    func glassCard(_ radius: CGFloat = 22) -> some View { modifier(GlassCard(radius: radius)) }
    /// Liste ou formulaire sur le fond commun.
    func gdScreen() -> some View { scrollContentBackground(.hidden).background(Backdrop()) }
}

/// Bandeau flottant des tâches en cours (compilation, envoi, publication).
struct ActivityBanner: View {
    @EnvironmentObject var b: BuildCenter
    var onTap: () -> Void

    var body: some View {
        let active = b.jobs.filter { $0.state.isActive }
        if let j = active.first {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(active.count > 1 ? "\(active.count) compilations en cours" : j.name)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(j.detail.isEmpty ? j.state.label : j.detail)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassCard(20)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

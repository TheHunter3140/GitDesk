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

// MARK: - Composants communs

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct Avatar: View {
    let text: String
    var color: Color = Theme.accent
    var size: CGFloat = 40
    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color, color.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct Chip: View {
    let text: String
    var color: Color = .blue
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.title3.weight(.bold)).foregroundColor(.primary).textCase(nil)
    }
}

struct ToolRow: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: color)
            Text(title).font(.body.weight(.medium)).foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassCard(16)
    }
}

struct RepoCard: View {
    let title: String
    let subtitle: String?
    let isPrivate: Bool
    let isLocal: Bool
    var body: some View {
        HStack(spacing: 12) {
            Avatar(text: title.split(separator: "/").last.map(String.init) ?? title, color: isPrivate ? .orange : Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundColor(.primary).lineLimit(1)
                if let d = subtitle, !d.isEmpty {
                    Text(d).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Chip(text: isPrivate ? "Privé" : "Public", color: isPrivate ? .orange : .green)
                    if isLocal { Chip(text: "Sur l'appareil", color: .blue) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassCard(18)
    }
}

struct DropZone: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 36))
                .foregroundStyle(LinearGradient(colors: [Theme.accent, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Choisir une archive").font(.headline).foregroundColor(.primary)
            Text("Fichiers, iCloud, AirDrop… ou glisse-la ici").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .glassCard(24)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
    }
}

extension View {
    /// Ligne de liste « carte » : sans séparateur ni fond, marges serrées.
    func cardRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
    }
}

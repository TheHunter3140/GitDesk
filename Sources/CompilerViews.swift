import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Écran principal

struct CompilerView: View {
    @EnvironmentObject var s: Session
    @EnvironmentObject var b: BuildCenter
    @Environment(\.scenePhase) private var phase
    @State private var picking = false
    @State private var showSettings = false
    @State private var errorText: String?
    @AppStorage("build_auto") private var auto = true

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Dépose une archive (ZIP, TAR, TAR.GZ) ou un dossier de code source. Le type de projet est détecté, le workflow est généré, la compilation tourne sur GitHub Actions et tu es notifié à la fin.")) {
                    Button { Haptic.tap(); picking = true } label: { DropZone() }
                        .buttonStyle(PressableStyle())
                        .cardRow()
                }

                Section(header: Text("Dossier surveillé"),
                        footer: Text(auto
                                     ? "Dans Fichiers : Sur mon iPhone → GitDesk → Builds. Tout ce que tu y déposes est détecté et compilé automatiquement ; l'original est rangé dans « Traitées » et le résultat arrive dans « Résultats »."
                                     : "Dans Fichiers : Sur mon iPhone → GitDesk → Builds. La compilation automatique est désactivée (réglages) : touche « Compiler » pour lancer.")) {
                    if b.inbox.isEmpty {
                        Label("Aucune archive en attente", systemImage: "tray").foregroundColor(.secondary)
                    }
                    ForEach(b.inbox) { it in
                        HStack(spacing: 12) {
                            Image(systemName: it.isFolder ? "folder.fill" : "doc.zipper")
                                .foregroundColor(it.supported ? .accentColor : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.name).lineLimit(1)
                                Text(it.supported ? (it.ready ? "Prête" : "Copie en cours…") : "Format non pris en charge (dossier, ZIP, TAR, TAR.GZ)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if it.supported && it.ready && !auto {
                                Button("Compiler") { b.compileNow(it, session: s) }
                                    .buttonStyle(.borderedProminent)
                            } else if it.supported && !it.ready {
                                ProgressView()
                            }
                        }
                        .padding(12).glassCard(16).cardRow()
                    }
                }

                if b.jobs.isEmpty {
                    Section { Text("Aucune compilation pour l'instant.").foregroundColor(.secondary) }
                } else {
                    Section("Compilations") {
                        ForEach(b.jobs) { j in
                            NavigationLink { BuildDetailView(jobId: j.id) } label: { BuildRow(job: j) }
                                .cardRow()
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { Haptic.warning(); b.delete(j.id, session: s) } label: { Label("Supprimer", systemImage: "trash") }
                                }
                                .swipeActions(edge: .leading) {
                                    if j.state.isActive && j.runId != nil {
                                        Button { b.cancel(j, session: s) } label: { Label("Annuler", systemImage: "xmark.circle") }.tint(.orange)
                                    } else if j.state == .success && j.publicURL == nil {
                                        Button { Haptic.tap(); b.publishNow(j.id, session: s) } label: { Label("Publier", systemImage: "icloud.and.arrow.up") }.tint(.blue)
                                    }
                                }
                                .contextMenu {
                                    if j.state.isActive && j.runId != nil {
                                        Button { b.cancel(j, session: s) } label: { Label("Annuler la compilation", systemImage: "xmark.circle") }
                                    }
                                    if j.state == .success && j.publicURL == nil {
                                        Button { b.publishNow(j.id, session: s) } label: { Label("Publier maintenant", systemImage: "icloud.and.arrow.up") }
                                    }
                                    Button(role: .destructive) { b.delete(j.id, session: s) } label: { Label("Supprimer", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Compiler")
            .gdScreen()
            .animation(.easeInOut(duration: 0.25), value: b.jobs)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable {
                await b.scanInbox()
                b.resumePending(session: s)
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let u = urls.first { start(u) }
                case .failure(let e): errorText = e.localizedDescription
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                start(u)
                return true
            }
            .sheet(isPresented: $showSettings) { CompilerSettingsView() }
            .onChange(of: phase) { p in
                if p == .active {
                    b.resumePending(session: s)
                    Task { await b.scanInbox() }
                }
            }
            .alert("Compiler", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func start(_ url: URL) {
        guard Archive.isArchive(url) else {
            errorText = "Dépose une archive ZIP, TAR, TAR.GZ ou TGZ."
            return
        }
        do { try b.submit(url, session: s) } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Ligne de liste

struct BuildStateIcon: View {
    let state: BuildState
    var body: some View {
        switch state {
        case .preparing, .queued, .running:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failure:
            Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
        case .cancelled:
            Image(systemName: "slash.circle.fill").foregroundColor(.gray)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }
}

struct BuildRow: View {
    let job: BuildJob

    private var color: Color {
        switch job.state {
        case .preparing, .queued, .running: return Theme.accent
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .gray
        case .error: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BuildStateIcon(state: job.state)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.headline).lineLimit(1)
                    Text(job.detail.isEmpty ? job.state.label : job.detail)
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
            if job.state.isActive { ProgressView().progressViewStyle(.linear) }
            HStack(spacing: 6) {
                if !job.kind.isEmpty { Chip(text: job.kind, color: .blue) }
                if job.publicURL != nil { Chip(text: "Publié", color: .green) }
                Spacer()
                Text(job.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .glassCard(18)
    }
}

// MARK: - Détail

struct BuildDetailView: View {
    let jobId: String
    @EnvironmentObject var b: BuildCenter
    @EnvironmentObject var s: Session

    private var job: BuildJob? { b.jobs.first { $0.id == jobId } }

    var body: some View {
        List {
            if let j = job {
                Section {
                    VStack(spacing: 10) {
                        BuildStateIcon(state: j.state).scaleEffect(1.8).frame(height: 46)
                        Text(j.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        Text(j.state.label).font(.subheadline).foregroundColor(.secondary)
                        if j.state.isActive { ProgressView().progressViewStyle(.linear) }
                    }
                    .frame(maxWidth: .infinity).padding(18).glassCard(24).cardRow()
                }
                Section {
                    if !j.detail.isEmpty {
                        Text(j.detail).font(.subheadline).foregroundColor(.secondary)
                    }
                    LabeledContent("Type", value: j.kind.isEmpty ? "—" : j.kind)
                    LabeledContent("Démarré", value: j.created.formatted(date: .abbreviated, time: .shortened))
                    if let f = j.finished {
                        LabeledContent("Durée", value: durationText(f.timeIntervalSince(j.created)))
                    }
                }
                if j.runURL != nil || j.releaseURL != nil {
                    Section {
                        if let u = j.runURL, let url = URL(string: u) {
                            Link(destination: url) { Label("Voir le run sur GitHub", systemImage: "arrow.up.right.square") }
                        }
                        if let u = j.releaseURL, let url = URL(string: u) {
                            Link(destination: url) { Label("Voir la release (dernière)", systemImage: "shippingbox") }
                        }
                    }
                }
                if j.state == .success {
                    Section(header: Text("Publication publique")) {
                        if let u = j.publicURL, let url = URL(string: u) {
                            Link(destination: url) { Label("Voir la publication", systemImage: "globe") }
                            ShareLink(item: url) { Label("Partager le lien", systemImage: "square.and.arrow.up") }
                        } else {
                            Button { Haptic.tap(); b.publishNow(j.id, session: s) } label: { Label("Publier maintenant", systemImage: "icloud.and.arrow.up") }
                        }
                        if let r = j.redacted, r > 0 {
                            Text("\(r) élément(s) sensible(s) retiré(s) du code publié.").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
                if (j.state == .running || j.state == .queued) && j.runId != nil {
                    Section {
                        Button("Annuler la compilation", role: .destructive) { b.cancel(j, session: s) }
                    }
                }
                if let dir = j.artifactDir {
                    resultSection(dir)
                } else if j.state == .success {
                    Section {
                        Text("Compilation terminée, mais aucun fichier n'a été récupéré. Regarde le détail sur GitHub.")
                            .foregroundColor(.secondary)
                    }
                }
                if let log = j.log, !log.isEmpty {
                    Section("Résumé du build") {
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(job?.name ?? "Compilation")
        .navigationBarTitleDisplayMode(.inline)
        .gdScreen()
    }

    @ViewBuilder
    private func resultSection(_ rel: String) -> some View {
        let dir = Paths.documents.appendingPathComponent(rel)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        Section(header: Text("Résultat"), footer: Text("Partage le fichier vers Fichiers, AirDrop ou ton outil de signature.")) {
            ForEach(files, id: \.self) { f in
                ShareLink(item: f) { Label(f.lastPathComponent, systemImage: "square.and.arrow.up") }
            }
            NavigationLink {
                FileBrowserView(dir: dir, title: "Résultat")
            } label: {
                Label("Ouvrir dans l'explorateur", systemImage: "folder")
            }
        }
    }

    private func durationText(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let sec = Int(t) % 60
        return m > 0 ? "\(m) min \(sec) s" : "\(sec) s"
    }
}

// MARK: - Réglages

struct CompilerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("build_repo") private var repo = "gitdesk-builds"
    @AppStorage("build_private") private var isPrivate = true
    @AppStorage("build_auto") private var auto = true
    @AppStorage("build_ntfy") private var ntfy = true
    @AppStorage("build_topic") private var topic = ""
    @AppStorage("build_publish") private var publish = true
    @AppStorage("build_public_repo") private var pubRepo = "gitdesk-public"
    @AppStorage("build_clean") private var clean = true

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Dossier Builds"),
                        footer: Text("Les archives et dossiers déposés dans Fichiers → GitDesk → Builds sont détectés dès que la copie est terminée (l'app doit être ouverte).")) {
                    Toggle("Compiler automatiquement", isOn: $auto)
                }
                Section(header: Text("Dépôt de compilation"),
                        footer: Text("Un seul dépôt réutilisé : chaque build a sa propre branche « build/… » et le résultat est publié dans une release « <projet>-latest » (remplacée à chaque build, avec le résumé des logs). Il est créé automatiquement. Dépôt privé : les minutes GitHub Actions sont limitées (les runners macOS comptent ×10). Dépôt public : gratuit, mais le code est visible.")) {
                    TextField("Nom du dépôt", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Privé (à la création)", isOn: $isPrivate)
                }
                Section(header: Text("Publication publique"),
                        footer: Text("Après une compilation réussie, le résultat, le code source nettoyé et une description sont publiés dans un dépôt PUBLIC séparé, créé automatiquement. Le dépôt privé ci-dessus reste inchangé avec tout le détail. Avant publication, GitDesk retire du code les jetons, clés, certificats, profils de signature, dossiers .git et identifiants d'équipe Apple, et publie avec une identité anonyme (ton jeton n'est jamais écrit nulle part). Ton nom d'utilisateur GitHub reste visible dans l'adresse du dépôt public. Un fichier retiré (par exemple google-services.json) n'est pas dans la copie publique. Sans nettoyage, le code source n'est pas publié.")) {
                    Toggle("Publier après la compilation", isOn: $publish)
                    TextField("Nom du dépôt public", text: $pubRepo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Nettoyer le code (secrets, clés…)", isOn: $clean)
                }
                Section(header: Text("Notifications"),
                        footer: Text("À la fin du workflow, GitHub envoie un push via ntfy, même si GitDesk est fermé. Installe l'app ntfy, appuie sur + et colle ce sujet (serveur ntfy.sh). Garde-le secret : toute personne qui le connaît peut le lire.")) {
                    Toggle("Notification push (ntfy)", isOn: $ntfy)
                    if ntfy {
                        TextField("Sujet ntfy", text: $topic)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Copier le sujet") { UIPasteboard.general.string = topic }
                        if let u = URL(string: "https://docs.ntfy.sh/subscribe/phone/") {
                            Link("Installer l'app ntfy", destination: u)
                        }
                    }
                }
                Section("À savoir") {
                    Text("Le token GitHub doit avoir les portées « repo » et « workflow ». Archive : 2 Go maximum (ZIP, TAR, TAR.GZ ou dossier) ; garde l'app ouverte pendant l'envoi. Une notification locale s'ajoute quand GitDesk est encore actif.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Réglages compilation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .onAppear { if topic.isEmpty { topic = BuildSettings.topic } }
        }
    }
}

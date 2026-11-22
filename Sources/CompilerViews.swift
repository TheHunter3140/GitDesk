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

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Dépose une archive ZIP, TAR ou TAR.GZ du code source. Le type de projet est détecté, le workflow est généré, la compilation tourne sur GitHub Actions et tu es notifié à la fin.")) {
                    Button { picking = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "shippingbox.and.arrow.backward.fill").font(.system(size: 34))
                            Text("Choisir ou déposer une archive").font(.headline)
                            Text("Fichiers, iCloud, AirDrop…").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    }
                }
                if b.jobs.isEmpty {
                    Section { Text("Aucune compilation pour l'instant.").foregroundColor(.secondary) }
                } else {
                    Section("Compilations") {
                        ForEach(b.jobs) { j in
                            NavigationLink { BuildDetailView(jobId: j.id) } label: { BuildRow(job: j) }
                        }
                        .onDelete { idx in
                            let ids = idx.map { b.jobs[$0].id }
                            for id in ids { b.delete(id, session: s) }
                        }
                    }
                }
            }
            .navigationTitle("Compiler")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { b.resumePending(session: s) }
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
                if p == .active { b.resumePending(session: s) }
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
    var body: some View {
        HStack(spacing: 12) {
            BuildStateIcon(state: job.state).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.headline).lineLimit(1)
                Text(job.detail.isEmpty ? job.state.label : job.detail)
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if !job.kind.isEmpty { Text(job.kind) }
                    Text(job.created.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
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
                    HStack(spacing: 10) {
                        BuildStateIcon(state: j.state)
                        Text(j.state.label).font(.headline)
                    }
                    if !j.detail.isEmpty {
                        Text(j.detail).font(.subheadline).foregroundColor(.secondary)
                    }
                    LabeledContent("Type", value: j.kind.isEmpty ? "—" : j.kind)
                    LabeledContent("Démarré", value: j.created.formatted(date: .abbreviated, time: .shortened))
                    if let f = j.finished {
                        LabeledContent("Durée", value: durationText(f.timeIntervalSince(j.created)))
                    }
                }
                if let u = j.runURL, let url = URL(string: u) {
                    Section {
                        Link(destination: url) { Label("Voir sur GitHub", systemImage: "arrow.up.right.square") }
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
                    Section("Journal (fin)") {
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(job?.name ?? "Compilation")
        .navigationBarTitleDisplayMode(.inline)
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
    @AppStorage("build_ntfy") private var ntfy = true
    @AppStorage("build_topic") private var topic = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Dépôt de compilation"),
                        footer: Text("Un seul dépôt réutilisé : chaque archive est envoyée sur sa propre branche « build/… ». Il est créé automatiquement. Dépôt privé : les minutes GitHub Actions sont limitées (les runners macOS comptent ×10). Dépôt public : gratuit, mais le code est visible.")) {
                    TextField("Nom du dépôt", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Privé (à la création)", isOn: $isPrivate)
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
                    Text("Le token GitHub doit avoir les portées « repo » et « workflow ». Archive : 50 Mo maximum, formats ZIP, TAR, TAR.GZ. Une notification locale s'ajoute quand GitDesk est encore actif.")
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

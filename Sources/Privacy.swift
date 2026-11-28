import SwiftUI
import UIKit
import AVFoundation

// MARK: - Nettoyage du code avant publication publique

enum SourceSanitizer {
    struct Report { var removed = 0; var redacted = 0; var total: Int { removed + redacted } }

    private static let dropDirs: Set<String> = [".git", ".svn", ".hg", ".gitdesk", ".idea", ".vscode", ".ssh", ".aws",
                                                ".gnupg", ".kube", "xcuserdata", "__MACOSX"]
    private static let dropNames: Set<String> = [".env", ".netrc", ".npmrc", ".pypirc", ".dockercfg", ".htpasswd",
                                                 "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials",
                                                 "credentials.json", "secrets.json", "secrets.yml", "secrets.yaml",
                                                 "service-account.json", "serviceaccount.json", "google-services.json",
                                                 "googleservice-info.plist", ".ds_store"]
    private static let dropExts: Set<String> = ["pem", "p12", "pfx", "p8", "key", "keystore", "jks", "mobileprovision",
                                                "provisionprofile", "gpg", "kdbx", "ppk"]
    private static let binaryExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "ico", "icns", "pdf", "zip",
                                                  "gz", "tgz", "tar", "7z", "rar", "ipa", "apk", "jar", "a", "o", "dylib",
                                                  "so", "mp3", "mp4", "mov", "wav", "ttf", "otf", "woff", "woff2", "gguf",
                                                  "bin", "car", "xcf", "psd"]

    private static let rules: [(NSRegularExpression, String)] = {
        let defs: [(String, String, NSRegularExpression.Options)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[CLÉ PRIVÉE RETIRÉE]", []),
            (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\bAIza[0-9A-Za-z_\-]{35}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\bsk_live_[A-Za-z0-9]{20,}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\bsk-[A-Za-z0-9_\-]{32,}\b"#, "[SECRET_RETIRÉ]", []),
            (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#, "[SECRET_RETIRÉ]", []),
            (#"(https?://)[^\s/:@"']+:[^\s/@"']+@"#, "$1", []),
            (#"[A-Za-z0-9._%+\-]+@users\.noreply\.github\.com"#, "[e-mail retiré]", []),
            (#"((?:api[_-]?key|apikey|secret|token|passw(?:or)?d|auth[_-]?token|access[_-]?key|private[_-]?key|client[_-]?secret)["']?\s*[:=]\s*)(["'])([^"'\s]{8,})\2"#,
             "$1$2[SECRET_RETIRÉ]$2", [.caseInsensitive]),
            (#"(DEVELOPMENT_TEAM\s*[=:]\s*)"?[A-Z0-9]{10}"?"#, "$1\"\"", []),
            (#"(PROVISIONING_PROFILE_SPECIFIER\s*[=:]\s*)"[^"]*""#, "$1\"\"", [])
        ]
        return defs.compactMap { d in
            guard let re = try? NSRegularExpression(pattern: d.0, options: d.2) else { return nil }
            return (re, d.1)
        }
    }()

    private static func shouldDrop(_ name: String) -> Bool {
        let l = name.lowercased()
        if dropNames.contains(l) { return true }
        if dropExts.contains((l as NSString).pathExtension) { return true }
        if l.hasPrefix(".env.") && !(l.hasSuffix(".example") || l.hasSuffix(".sample") || l.hasSuffix(".template") || l.hasSuffix(".dist")) { return true }
        if l.hasSuffix(".secret") || l.hasSuffix(".secrets") { return true }
        return false
    }

    /// Nettoie le dossier EN PLACE (à appeler sur une copie extraite, jamais sur l'original).
    static func clean(_ root: URL, token: String?) -> Report {
        let fm = FileManager.default
        var rep = Report()
        var drop: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return rep }
        for case let u as URL in en {
            let name = u.lastPathComponent
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if dropDirs.contains(name) { drop.append(u); en.skipDescendants() }
                continue
            }
            if shouldDrop(name) { drop.append(u); continue }
            if binaryExts.contains(u.pathExtension.lowercased()) { continue }
            let size = v?.fileSize ?? 0
            if size == 0 || size > 3_000_000 { continue }
            guard let data = try? Data(contentsOf: u), let text = String(data: data, encoding: .utf8) else { continue }
            var s = text
            var changed = 0
            if let t = token, t.count >= 8, s.contains(t) {
                changed += s.components(separatedBy: t).count - 1
                s = s.replacingOccurrences(of: t, with: "[SECRET_RETIRÉ]")
            }
            for (re, tpl) in rules {
                let r = NSRange(s.startIndex..., in: s)
                let n = re.numberOfMatches(in: s, range: r)
                if n > 0 {
                    changed += n
                    s = re.stringByReplacingMatches(in: s, range: r, withTemplate: tpl)
                }
            }
            if changed > 0 {
                let perms = (try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions]
                try? s.write(to: u, atomically: true, encoding: .utf8)
                if let p = perms { try? fm.setAttributes([.posixPermissions: p], ofItemAtPath: u.path) }
                rep.redacted += changed
            }
        }
        for u in drop where (try? fm.removeItem(at: u)) != nil { rep.removed += 1 }
        return rep
    }
}

// MARK: - Écran allumé, travail en arrière-plan, mémoire

final class ActivityKeeper: @unchecked Sendable {
    static let shared = ActivityKeeper()
    private let lock = NSLock()
    private var holds = Set<String>()
    private var player: AVAudioPlayer?
    private var observing = false

    private var keepScreen: Bool { UserDefaults.standard.object(forKey: "keep_screen") as? Bool ?? true }
    private var keepAlive: Bool { UserDefaults.standard.object(forKey: "keep_alive") as? Bool ?? true }

    func hold(_ key: String) {
        lock.lock(); holds.insert(key); lock.unlock()
        refresh()
    }

    func release(_ key: String) {
        lock.lock(); holds.remove(key); lock.unlock()
        refresh()
    }

    func refresh() { Task { @MainActor in self.apply() } }

    private var active: Bool { lock.lock(); defer { lock.unlock() }; return !holds.isEmpty }

    @MainActor private func apply() {
        let on = active
        UIApplication.shared.isIdleTimerDisabled = on && keepScreen
        if on && keepAlive { startAudio() } else { stopAudio() }
    }

    @MainActor private func startAudio() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        if player?.isPlaying == true { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silence())
                p.numberOfLoops = -1
                p.volume = 0
                player = p
            }
            player?.play()
        } catch {}
    }

    @MainActor private func stopAudio() {
        guard player != nil else { return }
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Une seconde de silence (WAV 16 bits mono 8 kHz) en mémoire.
    private static func silence() -> Data {
        let rate: UInt32 = 8000
        let dataSize: UInt32 = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}

enum Memory {
    static func install() {
        Thumbs.cache.countLimit = 250
        Thumbs.cache.totalCostLimit = 48_000_000
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            trim()
        }
    }

    static func trim() {
        Thumbs.cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }
}

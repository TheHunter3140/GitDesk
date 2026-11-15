import SwiftUI
import UIKit

struct EditorView: View {
    @ObservedObject var ws: Workspace
    let path: String
    @AppStorage("fontSize") private var fontSize = 14.0
    @State private var text = ""
    @State private var mode: Mode = .loading
    @State private var imageData: Data?
    @State private var lastSaved = ""
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?

    enum Mode { case loading, text, image, binary, tooBig }
    private var url: URL { ws.root.appendingPathComponent(path) }

    var body: some View {
        Group {
            switch mode {
            case .loading: ProgressView()
            case .text:
                CodeTextView(text: $text, ext: (path as NSString).pathExtension.lowercased(), fontSize: CGFloat(fontSize))
            case .image:
                if let d = imageData, let img = UIImage(data: d) {
                    ScrollView([.horizontal, .vertical]) { Image(uiImage: img) }
                } else { Text("Image illisible").foregroundColor(.secondary) }
            case .binary: Text("Fichier binaire : aperçu indisponible.").foregroundColor(.secondary).padding()
            case .tooBig: Text("Fichier trop volumineux pour l'éditeur (> 1,5 Mo).").foregroundColor(.secondary).padding()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button("Texte plus grand") { fontSize = min(fontSize + 1, 28) }
                    Button("Texte plus petit") { fontSize = max(fontSize - 1, 9) }
                } label: { Image(systemName: "textformat.size") }
                Button("Enregistrer") { save() }.disabled(!dirty)
            }
        }
        .onAppear { load() }
        .onDisappear { saveTask?.cancel(); save() }
        .onChange(of: text) { _ in
            guard mode == .text, text != lastSaved else { return }
            dirty = true
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if !Task.isCancelled { save() }
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { lastSaved = ""; text = ""; mode = .text; return }
        if data.count > 1_500_000 { mode = .tooBig; return }
        if let s = String(data: data, encoding: .utf8) { lastSaved = s; text = s; mode = .text }
        else if UIImage(data: data) != nil { imageData = data; mode = .image }
        else { mode = .binary }
    }

    private func save() {
        guard mode == .text, dirty else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lastSaved = text
        dirty = false
        Task { await ws.refresh() }
    }
}

struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var ext: String
    var fontSize: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.alwaysBounceVertical = true
        tv.backgroundColor = .systemBackground
        tv.inputAccessoryView = context.coordinator.makeBar(tv)
        tv.text = text
        Highlighter.apply(tv, ext: ext)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        var redo = false
        if tv.text != text { tv.text = text; redo = true }
        if tv.font?.pointSize != fontSize { tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular); redo = true }
        if redo { Highlighter.apply(tv, ext: ext) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        init(_ p: CodeTextView) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            if tv.markedTextRange == nil { Highlighter.apply(tv, ext: parent.ext) }
        }

        func makeBar(_ tv: UITextView) -> UIToolbar {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            var items: [UIBarButtonItem] = []
            let syms: [(String, String)] = [("⇥", "    "), ("{", "{"), ("}", "}"), ("(", "("), (")", ")"),
                                           ("[", "["), ("]", "]"), ("\"", "\""), ("=", "="), (";", ";"), ("#", "#")]
            items.append(UIBarButtonItem(primaryAction: UIAction(title: "↶") { [weak tv] _ in tv?.undoManager?.undo() }))
            items.append(UIBarButtonItem(primaryAction: UIAction(title: "↷") { [weak tv] _ in tv?.undoManager?.redo() }))
            items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
            for (label, ins) in syms {
                items.append(UIBarButtonItem(primaryAction: UIAction(title: label) { [weak tv] _ in tv?.insertText(ins) }))
                items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
            }
            items.append(UIBarButtonItem(barButtonSystemItem: .done, target: tv, action: #selector(UIResponder.resignFirstResponder)))
            bar.items = items
            return bar
        }
    }
}

enum Highlighter {
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "class", "struct", "enum", "import", "def", "from",
        "as", "in", "is", "not", "and", "or", "None", "True", "False", "nil", "null", "true", "false", "const", "function",
        "async", "await", "try", "catch", "throw", "throws", "switch", "case", "default", "break", "continue", "public",
        "private", "static", "final", "new", "this", "self", "super", "extends", "implements", "interface", "protocol",
        "extension", "guard", "where", "lambda", "with", "yield", "pass", "raise", "except", "finally", "package", "type",
        "fn", "mut", "use", "impl", "pub", "match", "void", "int", "string", "bool"
    ]
    static let plain: Set<String> = ["md", "txt", "log", "csv"]
    static let hashComment: Set<String> = ["py", "sh", "bash", "zsh", "yml", "yaml", "toml", "rb", "pl", "r", "cfg", "ini", "conf", "env", "mk", "cmake"]

    private static let rxWord = try! NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b")
    private static let rxNumber = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    private static let rxString = try! NSRegularExpression(pattern: "\"(\\\\.|[^\"\\\\\\n])*\"|'(\\\\.|[^'\\\\\\n])*'")
    private static let rxLineC = try! NSRegularExpression(pattern: "//.*")
    private static let rxHash = try! NSRegularExpression(pattern: "#.*")
    private static let rxBlock = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")

    static func apply(_ tv: UITextView, ext: String) {
        let ts = tv.textStorage
        let len = ts.length
        let font = tv.font ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let full = NSRange(location: 0, length: len)
        ts.beginEditing()
        ts.setAttributes([.font: font, .foregroundColor: UIColor.label], range: full)
        if len > 0 && len < 150_000 && !plain.contains(ext) {
            let s = ts.string
            let ns = s as NSString
            rxWord.enumerateMatches(in: s, range: full) { m, _, _ in
                guard let r = m?.range, keywords.contains(ns.substring(with: r)) else { return }
                ts.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: r)
            }
            paint(rxNumber, s, full, ts, .systemBlue)
            paint(rxString, s, full, ts, .systemOrange)
            paint(rxBlock, s, full, ts, .systemGreen)
            paint(hashComment.contains(ext) ? rxHash : rxLineC, s, full, ts, .systemGreen)
        }
        ts.endEditing()
    }

    private static func paint(_ rx: NSRegularExpression, _ s: String, _ full: NSRange, _ ts: NSTextStorage, _ c: UIColor) {
        rx.enumerateMatches(in: s, range: full) { m, _, _ in
            if let r = m?.range { ts.addAttribute(.foregroundColor, value: c, range: r) }
        }
    }
}

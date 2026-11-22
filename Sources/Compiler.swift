import Foundation

// MARK: - Types de projets reconnus

enum ProjectKind: String {
    case xcodegen = "XcodeGen (iOS)"
    case xcode = "Xcode (iOS)"
    case swiftPackage = "Swift Package"
    case android = "Android (Gradle)"
    case gradle = "Gradle / Java"
    case rust = "Rust"
    case go = "Go"
    case cmake = "C/C++ (CMake)"
    case make = "Make"
    case node = "Node.js"
    case python = "Python"
    case dotnet = ".NET"
    case c = "C"
    case cpp = "C++"
    case java = "Java"
}

struct BuildPlan {
    var kind: ProjectKind
    var runner: String
    var steps: String          // étapes YAML, écrites à partir de la colonne 0
    var artifacts: [String]    // chemins relatifs à la racine du projet ("!" au début = exclusion)
}

func safeFileName(_ s: String) -> String {
    let t = s.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") ? String($0) : "-" }.joined()
    return t.isEmpty ? "build" : t
}

func asciiSlug(_ s: String) -> String {
    var out = ""
    for u in s.lowercased().unicodeScalars {
        if u.isASCII, CharacterSet.alphanumerics.contains(u) { out.unicodeScalars.append(u) } else { out += "-" }
    }
    out = out.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    out = String(out.prefix(30))
    return out.isEmpty ? "build" : out
}

// MARK: - Détection

enum Detector {
    static let ignored: Set<String> = ["__MACOSX", ".DS_Store"]

    static func list(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !ignored.contains($0) }
            .sorted()
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Descend dans les dossiers « enveloppe » (archive qui contient un seul dossier à la racine).
    static func flatten(_ base: URL) -> (url: URL, rel: [String]) {
        var cur = base
        var rel: [String] = []
        for _ in 0..<4 {
            let names = list(cur)
            guard names.count == 1 else { break }
            let name = names[0]
            if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") { break }
            let next = cur.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: next.path, isDirectory: &isDir), isDir.boolValue else { break }
            cur = next
            rel.append(name)
        }
        return (cur, rel)
    }

    static func plan(root: URL, rootPath: String) throws -> BuildPlan {
        let top = list(root)
        func has(_ n: String) -> Bool { top.contains(n) }
        func hasExt(_ e: String) -> Bool { top.contains { $0.lowercased().hasSuffix("." + e) } }

        let yml = read(root.appendingPathComponent("project.yml"))
        if has("project.yml") && yml.contains("targets:") { return xcodegen(yml) }
        if hasExt("xcworkspace") || hasExt("xcodeproj") { return xcode(pods: has("Podfile")) }
        if has("Package.swift") { return swiftPackage() }
        if has("build.gradle") || has("build.gradle.kts") || has("settings.gradle") || has("settings.gradle.kts") {
            return gradle(android: isAndroid(root), wrapper: has("gradlew"))
        }
        if has("Cargo.toml") { return rust() }
        if has("go.mod") { return go(rootPath: rootPath) }
        if has("CMakeLists.txt") { return cmake() }
        if has("Makefile") || has("makefile") || has("GNUmakefile") { return make() }
        if has("package.json") { return node() }
        if has("pyproject.toml") || has("setup.py") || has("requirements.txt") { return python() }
        if hasExt("sln") || hasExt("csproj") { return dotnet() }

        // Fichiers sources isolés
        var java = 0, cpp = 0, c = 0
        if let en = FileManager.default.enumerator(atPath: root.path) {
            for case let f as String in en {
                let l = f.lowercased()
                if l.hasSuffix(".java") { java += 1 }
                else if l.hasSuffix(".cpp") || l.hasSuffix(".cc") || l.hasSuffix(".cxx") { cpp += 1 }
                else if l.hasSuffix(".c") { c += 1 }
            }
        }
        if java > 0 { return javaPlan() }
        if cpp > 0 { return cppPlan() }
        if c > 0 { return cPlan() }
        throw APIError.message("Type de projet non reconnu (aucun project.yml, .xcodeproj, Package.swift, Gradle, Cargo, go.mod, CMake, Makefile, package.json, pyproject, .csproj ni source C/C++/Java à la racine).")
    }

    static func isAndroid(_ root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("app/src/main/AndroidManifest.xml").path) { return true }
        for f in ["build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts"] {
            if read(root.appendingPathComponent(f)).contains("com.android") { return true }
        }
        return false
    }

    // MARK: Plans

    static func xcodegen(_ yml: String) -> BuildPlan {
        var name = "App"
        for line in yml.split(separator: "\n") where line.hasPrefix("name:") {
            name = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            break
        }
        let steps = #"""
        - name: Installer XcodeGen
          run: brew install xcodegen
        - name: Générer le projet
          run: xcodegen generate
        - name: Compiler (non signé)
          run: |
            PROJ=$(ls -d *.xcodeproj | head -1)
            xcodebuild -project "$PROJ" -scheme "\#(name)" -configuration Release \
              -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
              CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
        - name: Fabriquer l'IPA
          run: |
            mkdir -p Payload out
            cp -R build/Build/Products/Release-iphoneos/*.app Payload/
            zip -qr "out/$(basename Payload/*.app .app).ipa" Payload
        """#
        return BuildPlan(kind: .xcodegen, runner: "macos-15", steps: steps, artifacts: ["out"])
    }

    static func xcode(pods: Bool) -> BuildPlan {
        let pod = pods ? "- name: CocoaPods\n  run: pod install" : ""
        let main = #"""
        - name: Compiler (non signé)
          run: |
            if W=$(ls -d *.xcworkspace 2>/dev/null | head -1) && [ -n "$W" ]; then ARGS=(-workspace "$W"); else ARGS=(-project "$(ls -d *.xcodeproj | head -1)"); fi
            SCHEME=$(xcodebuild -list -json "${ARGS[@]}" | python3 -c 'import json,sys; d=json.load(sys.stdin); x=d.get("workspace") or d.get("project"); print(x["schemes"][0])')
            xcodebuild "${ARGS[@]}" -scheme "$SCHEME" -configuration Release \
              -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
              CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
        - name: Fabriquer l'IPA
          run: |
            mkdir -p Payload out
            cp -R build/Build/Products/Release-iphoneos/*.app Payload/
            zip -qr "out/$(basename Payload/*.app .app).ipa" Payload
        """#
        let steps = [pod, main].filter { !$0.isEmpty }.joined(separator: "\n")
        return BuildPlan(kind: .xcode, runner: "macos-15", steps: steps, artifacts: ["out"])
    }

    static func swiftPackage() -> BuildPlan {
        let steps = #"""
        - name: Compiler
          run: swift build -c release
        - name: Collecter les exécutables
          run: |
            mkdir -p out
            find .build/release -maxdepth 1 -type f -perm -111 -exec cp {} out/ \;
        """#
        return BuildPlan(kind: .swiftPackage, runner: "macos-15", steps: steps, artifacts: ["out"])
    }

    static func gradle(android: Bool, wrapper: Bool) -> BuildPlan {
        let cmd = wrapper ? "./gradlew" : "gradle"
        let task = android ? "assembleDebug" : "build"
        let java = #"""
        - uses: actions/setup-java@v4
          with:
            distribution: temurin
            java-version: '17'
        """#
        let setup = wrapper ? "" : "- uses: gradle/actions/setup-gradle@v4"
        let build = #"""
        - name: Compiler
          run: |
            chmod +x gradlew 2>/dev/null || true
            \#(cmd) \#(task) --no-daemon
        """#
        let steps = [java, setup, build].filter { !$0.isEmpty }.joined(separator: "\n")
        return BuildPlan(kind: android ? .android : .gradle, runner: "ubuntu-latest", steps: steps,
                         artifacts: [android ? "**/build/outputs/apk/**/*.apk" : "**/build/libs/*.jar"])
    }

    static func rust() -> BuildPlan {
        let steps = #"""
        - name: Compiler
          run: cargo build --release
        - name: Collecter les exécutables
          run: |
            mkdir -p out
            find target/release -maxdepth 1 -type f -perm -111 -exec cp {} out/ \;
        """#
        return BuildPlan(kind: .rust, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func go(rootPath: String) -> BuildPlan {
        let steps = #"""
        - uses: actions/setup-go@v5
          with:
            go-version-file: "\#(rootPath)/go.mod"
        - name: Compiler
          run: |
            mkdir -p out
            go build -o out/ ./...
        """#
        return BuildPlan(kind: .go, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func cmake() -> BuildPlan {
        let steps = #"""
        - name: Compiler
          run: |
            cmake -B build -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j
            mkdir -p out
            find build -type f -perm -111 ! -path '*/CMakeFiles/*' ! -name '*.cmake' -exec cp {} out/ \;
        """#
        return BuildPlan(kind: .cmake, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func make() -> BuildPlan {
        let steps = #"""
        - name: Compiler
          run: |
            find . -type f -not -path './.git/*' | sort > /tmp/before.txt
            make -j"$(nproc)"
            mkdir -p out
            find . -type f -not -path './.git/*' -not -path './out/*' | sort > /tmp/after.txt
            comm -13 /tmp/before.txt /tmp/after.txt | while read -r f; do cp --parents "$f" out/; done
        """#
        return BuildPlan(kind: .make, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func node() -> BuildPlan {
        let steps = #"""
        - uses: actions/setup-node@v4
          with:
            node-version: 20
        - name: Installer les dépendances
          run: npm ci || npm install
        - name: Compiler
          run: npm run build --if-present
        """#
        return BuildPlan(kind: .node, runner: "ubuntu-latest", steps: steps, artifacts: ["dist", "build", "out"])
    }

    static func python() -> BuildPlan {
        let steps = #"""
        - uses: actions/setup-python@v5
          with:
            python-version: '3.12'
        - name: Compiler
          run: |
            python -m pip install --upgrade pip build
            if [ -f pyproject.toml ] || [ -f setup.py ]; then
              python -m build
            else
              if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
              python -m compileall -q .
            fi
        """#
        return BuildPlan(kind: .python, runner: "ubuntu-latest", steps: steps, artifacts: ["dist"])
    }

    static func dotnet() -> BuildPlan {
        let steps = #"""
        - uses: actions/setup-dotnet@v4
          with:
            dotnet-version: 8.0.x
        - name: Compiler
          run: dotnet publish -c Release -o out
        """#
        return BuildPlan(kind: .dotnet, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func cPlan() -> BuildPlan {
        let steps = #"""
        - name: Compiler
          run: |
            mkdir -p out
            gcc -O2 -o out/app $(find . -name '*.c')
        """#
        return BuildPlan(kind: .c, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func cppPlan() -> BuildPlan {
        let steps = #"""
        - name: Compiler
          run: |
            mkdir -p out
            g++ -O2 -std=c++17 -o out/app $(find . -name '*.cpp' -o -name '*.cc' -o -name '*.cxx')
        """#
        return BuildPlan(kind: .cpp, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }

    static func javaPlan() -> BuildPlan {
        let steps = #"""
        - uses: actions/setup-java@v4
          with:
            distribution: temurin
            java-version: '17'
        - name: Compiler
          run: |
            mkdir -p out
            javac -d out $(find . -name '*.java')
        """#
        return BuildPlan(kind: .java, runner: "ubuntu-latest", steps: steps, artifacts: ["out"])
    }
}

// MARK: - Workflow

enum WorkflowBuilder {
    static func ind(_ s: String, _ n: Int) -> String {
        let pad = String(repeating: " ", count: n)
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }

    static func yq(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func make(plan: BuildPlan, root: String, extract: String, title: String, topic: String?) -> String {
        let head = #"""
        name: GitDesk Build
        on:
          push:
            branches: ['build/**']
        jobs:
          build:
            runs-on: \#(plan.runner)
            timeout-minutes: 90
            defaults:
              run:
                working-directory: "\#(yq(root))"
            steps:
              - uses: actions/checkout@v4
              - name: Extraire l'archive
                working-directory: .
                run: |
                  mkdir -p src
                  \#(extract)
        """#

        var upLines = ["- name: Publier le résultat", "  uses: actions/upload-artifact@v4", "  with:", "    name: gitdesk-build", "    path: |"]
        for a in plan.artifacts {
            let p = a.hasPrefix("!") ? "!" + root + "/" + String(a.dropFirst()) : root + "/" + a
            upLines.append("      " + p)
        }
        upLines.append("    if-no-files-found: warn")
        let upload = ind(upLines.joined(separator: "\n"), 6)

        var out = head + "\n" + ind(plan.steps, 6) + "\n" + upload + "\n"

        if let topic {
            let t = String(topic.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            var ascii = ""
            for u in title.unicodeScalars {
                let bad = !u.isASCII || u.value < 32 || u == "\"" || u == "\\" || u == "$" || u == "`"
                ascii += bad ? "-" : String(Character(u))
            }
            if !t.isEmpty {
                let notify = #"""
                - name: Notifier
                  if: always()
                  working-directory: .
                  env:
                    STATUS: ${{ job.status }}
                    RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
                  run: |
                    if [ "$STATUS" = "success" ]; then TAG=white_check_mark; MSG="Compilation réussie"; else TAG=x; MSG="Compilation échouée ($STATUS)"; fi
                    curl -fsS -m 20 -H "Title: GitDesk - \#(ascii)" -H "Tags: $TAG" -H "Click: $RUN_URL" -d "$MSG" "https://ntfy.sh/\#(t)" || true
                """#
                out += ind(notify, 6) + "\n"
            }
        }
        return out
    }
}

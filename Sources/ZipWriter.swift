import Foundation

/// Crée une archive ZIP (méthode « stockée », sans compression) à partir d'un dossier.
/// Les bits d'exécution sont conservés pour que `unzip` les restaure sur le runner (gradlew, scripts…).
enum ZipWriter {
    static let skipped: Set<String> = [".git", "node_modules", "__MACOSX", ".DS_Store", "DerivedData", ".build", ".gradle"]

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data, _ previous: UInt32 = 0) -> UInt32 {
        var c = ~previous
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let exec: Bool
    }

    @discardableResult
    static func zip(directory: URL, to dest: URL) throws -> Int {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw APIError.message("Impossible de créer l'archive temporaire.")
        }
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }

        guard let en = fm.enumerator(atPath: directory.path) else {
            throw APIError.message("Impossible de lire le dossier.")
        }

        var entries: [Entry] = []
        var offset: UInt64 = 0

        for case let rel as String in en {
            let comps = rel.split(separator: "/").map(String.init)
            let full = directory.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDir) else { continue }
            if comps.contains(where: { skipped.contains($0) }) {
                if isDir.boolValue { en.skipDescendants() }
                continue
            }
            if isDir.boolValue { continue }

            let attrs = (try? fm.attributesOfItem(atPath: full.path)) ?? [:]
            if let t = attrs[.type] as? FileAttributeType, t == .typeSymbolicLink { continue }
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let exec = (perms & 0o111) != 0

            let data = try Data(contentsOf: full, options: .mappedIfSafe)
            guard data.count < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else {
                throw APIError.message("Dossier trop volumineux pour être compressé (4 Go maximum).")
            }
            let crc = crc32(data)
            let name = Data(rel.utf8)

            var h = Data()
            h.le32(0x04034b50)
            h.le16(20)
            h.le16(0x0800)
            h.le16(0)
            h.le16(0)
            h.le16(0x21)
            h.le32(crc)
            h.le32(UInt32(data.count))
            h.le32(UInt32(data.count))
            h.le16(UInt16(name.count))
            h.le16(0)
            h.append(name)

            try out.write(contentsOf: h)
            try out.write(contentsOf: data)
            entries.append(Entry(name: name, crc: crc, size: UInt32(data.count), offset: UInt32(offset), exec: exec))
            offset += UInt64(h.count) + UInt64(data.count)
        }

        guard !entries.isEmpty else { throw APIError.message("Le dossier est vide.") }
        guard entries.count < 0xFFFF else { throw APIError.message("Trop de fichiers dans le dossier (65 534 maximum).") }

        var cd = Data()
        for e in entries {
            cd.le32(0x02014b50)
            cd.le16((3 << 8) | 20)
            cd.le16(20)
            cd.le16(0x0800)
            cd.le16(0)
            cd.le16(0)
            cd.le16(0x21)
            cd.le32(e.crc)
            cd.le32(e.size)
            cd.le32(e.size)
            cd.le16(UInt16(e.name.count))
            cd.le16(0)
            cd.le16(0)
            cd.le16(0)
            cd.le16(0)
            cd.le32(UInt32(e.exec ? 0o100755 : 0o100644) << 16)
            cd.le32(e.offset)
            cd.append(e.name)
        }
        guard offset + UInt64(cd.count) < 0xFFFF_FFFF else {
            throw APIError.message("Dossier trop volumineux pour être compressé (4 Go maximum).")
        }
        var end = Data()
        end.le32(0x06054b50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(entries.count))
        end.le16(UInt16(entries.count))
        end.le32(UInt32(cd.count))
        end.le32(UInt32(offset))
        end.le16(0)

        try out.write(contentsOf: cd)
        try out.write(contentsOf: end)
        return entries.count
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func le32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}

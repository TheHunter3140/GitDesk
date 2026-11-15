import Foundation
import Compression

enum ArchiveError: LocalizedError {
    case unsupported
    case corrupt(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Format non pris en charge (ZIP, TAR, TAR.GZ, GZ)."
        case .corrupt(let m): return "Archive illisible : \(m)."
        }
    }
}

private struct Reader {
    let d: Data
    func u16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= d.count else { throw ArchiveError.corrupt("fin de fichier inattendue") }
        return Int(d[d.startIndex + o]) | (Int(d[d.startIndex + o + 1]) << 8)
    }
    func u32(_ o: Int) throws -> Int {
        let lo = try u16(o)
        let hi = try u16(o + 2)
        return lo | (hi << 16)
    }
    func slice(_ o: Int, _ n: Int) throws -> Data {
        guard o >= 0, n >= 0, o + n <= d.count else { throw ArchiveError.corrupt("fin de fichier inattendue") }
        return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + n))
    }
}

enum Archive {
    static func isArchive(_ url: URL) -> Bool {
        ["zip", "tar", "gz", "tgz"].contains(url.pathExtension.lowercased())
    }

    static func baseName(_ url: URL) -> String {
        var n = url.lastPathComponent
        for s in [".tar.gz", ".tgz", ".zip", ".tar", ".gz"] where n.lowercased().hasSuffix(s) {
            n = String(n.dropLast(s.count))
            break
        }
        return n.isEmpty ? "Archive" : n
    }

    @discardableResult
    static func extract(_ src: URL, to dest: URL) throws -> Int {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        let name = src.lastPathComponent.lowercased()
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || name.hasSuffix(".zip") { return try unzip(data, to: dest) }
        if data.starts(with: [0x1f, 0x8b]) {
            let raw = try gunzip(data)
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || looksLikeTar(raw) { return try untar(raw, to: dest) }
            try raw.write(to: dest.appendingPathComponent(baseName(src)))
            return 1
        }
        if name.hasSuffix(".tar") || looksLikeTar(data) { return try untar(data, to: dest) }
        throw ArchiveError.unsupported
    }

    private static func looksLikeTar(_ d: Data) -> Bool {
        guard d.count >= 512 else { return false }
        return d.subdata(in: (d.startIndex + 257)..<(d.startIndex + 262)) == Data("ustar".utf8)
    }

    // Chemin sûr : refuse "..", chemins absolus et __MACOSX
    private static func target(_ root: URL, _ name: String) -> URL? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        if parts.isEmpty || parts.contains("..") || parts.first == "__MACOSX" { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    // MARK: ZIP
    private static func unzip(_ data: Data, to dest: URL) throws -> Int {
        let r = Reader(d: data)
        let fm = FileManager.default
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 65535)
        while i >= lowest {
            if try r.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.corrupt("répertoire central introuvable") }
        let total = try r.u16(eocd + 10)
        let cdOff = try r.u32(eocd + 16)
        if total == 0xFFFF || cdOff == 0xFFFFFFFF { throw ArchiveError.corrupt("ZIP64 non pris en charge") }
        var p = cdOff
        var count = 0
        for _ in 0..<total {
            guard try r.u32(p) == 0x02014b50 else { throw ArchiveError.corrupt("entrée invalide") }
            let flags = try r.u16(p + 8)
            let method = try r.u16(p + 10)
            let csize = try r.u32(p + 20)
            let usize = try r.u32(p + 24)
            let nlen = try r.u16(p + 28)
            let xlen = try r.u16(p + 30)
            let clen = try r.u16(p + 32)
            let lho = try r.u32(p + 42)
            let nameData = try r.slice(p + 46, nlen)
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            p += 46 + nlen + xlen + clen
            guard let out = target(dest, name) else { continue }
            if name.hasSuffix("/") { try fm.createDirectory(at: out, withIntermediateDirectories: true); continue }
            if flags & 1 != 0 { throw ArchiveError.corrupt("archive chiffrée non prise en charge") }
            guard try r.u32(lho) == 0x04034b50 else { throw ArchiveError.corrupt("en-tête local invalide") }
            let lnlen = try r.u16(lho + 26)
            let lxlen = try r.u16(lho + 28)
            let payload = try r.slice(lho + 30 + lnlen + lxlen, csize)
            let content: Data
            switch method {
            case 0: content = payload
            case 8:
                content = try inflate(payload)
                if content.count != usize { throw ArchiveError.corrupt("taille incorrecte pour \(name)") }
            default: throw ArchiveError.corrupt("méthode de compression \(method) non prise en charge")
            }
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: out)
            count += 1
        }
        return count
    }

    // MARK: GZIP
    private static func gunzip(_ d: Data) throws -> Data {
        guard d.count > 18, d[d.startIndex] == 0x1f, d[d.startIndex + 1] == 0x8b, d[d.startIndex + 2] == 8 else {
            throw ArchiveError.corrupt("en-tête gzip")
        }
        let r = Reader(d: d)
        let flg = Int(d[d.startIndex + 3])
        var p = 10
        if flg & 4 != 0 { let xl = try r.u16(p); p += 2 + xl }
        if flg & 8 != 0 { while p < d.count && d[d.startIndex + p] != 0 { p += 1 }; p += 1 }
        if flg & 16 != 0 { while p < d.count && d[d.startIndex + p] != 0 { p += 1 }; p += 1 }
        if flg & 2 != 0 { p += 2 }
        guard p < d.count - 8 else { throw ArchiveError.corrupt("gzip tronqué") }
        let body = try r.slice(p, d.count - 8 - p)
        return try inflate(body)
    }

    // MARK: Deflate brut (Compression : COMPRESSION_ZLIB = DEFLATE sans en-tête)
    private static func inflate(_ src: Data) throws -> Data {
        if src.isEmpty { return Data() }
        let bufSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.corrupt("initialisation deflate")
        }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        try src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = src.count
            stream.dst_ptr = dst
            stream.dst_size = bufSize
            var idle = 0
            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufSize - stream.dst_size
                if produced > 0 { out.append(dst, count: produced); idle = 0 } else { idle += 1 }
                stream.dst_ptr = dst
                stream.dst_size = bufSize
                if status == COMPRESSION_STATUS_END { return }
                if status != COMPRESSION_STATUS_OK || idle > 3 { throw ArchiveError.corrupt("flux deflate invalide") }
            }
        }
        return out
    }

    // MARK: TAR
    private static func untar(_ d: Data, to dest: URL) throws -> Int {
        let fm = FileManager.default
        var p = 0
        var count = 0
        var longName: String?
        var paxPath: String?
        while p + 512 <= d.count {
            let h = d.subdata(in: (d.startIndex + p)..<(d.startIndex + p + 512))
            if h.allSatisfy({ $0 == 0 }) { break }
            func str(_ a: Int, _ n: Int) -> String {
                String(decoding: h[(h.startIndex + a)..<(h.startIndex + a + n)].prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let size = Int(str(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = h[h.startIndex + 156]
            var name = str(0, 100)
            let prefix = str(345, 155)
            if !prefix.isEmpty && str(257, 5) == "ustar" { name = prefix + "/" + name }
            let dataStart = p + 512
            guard dataStart + size <= d.count else { throw ArchiveError.corrupt("tar tronqué") }
            let body = d.subdata(in: (d.startIndex + dataStart)..<(d.startIndex + dataStart + size))
            p = dataStart + ((size + 511) / 512) * 512
            if type == UInt8(ascii: "L") { longName = String(decoding: body.prefix(while: { $0 != 0 }), as: UTF8.self); continue }
            if type == UInt8(ascii: "x") { paxPath = paxValue(body, key: "path"); continue }
            if type == UInt8(ascii: "g") { continue }
            if let l = longName { name = l; longName = nil }
            if let x = paxPath { name = x; paxPath = nil }
            guard let out = target(dest, name) else { continue }
            if type == UInt8(ascii: "5") || name.hasSuffix("/") {
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                continue
            }
            if type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7") {
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: out)
                count += 1
            }
        }
        return count
    }

    private static func paxValue(_ d: Data, key: String) -> String? {
        let text = String(decoding: d, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let sp = line.firstIndex(of: " ") else { continue }
            let rec = line[line.index(after: sp)...]
            if rec.hasPrefix(key + "=") { return String(rec.dropFirst(key.count + 1)) }
        }
        return nil
    }
}

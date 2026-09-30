import Foundation

/// Minimal ZIP support with no third-party dependency.
///
/// Reader: enough of PKZIP to open Office Open XML packages (.docx, .xlsx,
/// .pptx) and iWork bundles: central directory walk, stored and deflated
/// entries. Deflate is handled by Foundation (`.zlib` is raw DEFLATE, which
/// is exactly what ZIP stores).
///
/// Writer: stored (uncompressed) entries with CRC-32, which is a valid
/// archive every consumer accepts. Used to produce .docx files; the text
/// parts are tiny and embedded JPEGs don't compress anyway.
enum ZipArchive {
    enum ZipError: LocalizedError {
        case notAZip
        case unsupportedCompression(Int)
        case corrupt

        var errorDescription: String? {
            switch self {
            case .notAZip: "The file isn't a valid package."
            case .unsupportedCompression: "The package uses unsupported compression."
            case .corrupt: "The package is damaged."
            }
        }
    }

    // MARK: - Reading

    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    final class Reader {
        private let data: Data
        private(set) var entries: [String: Entry] = [:]

        init(url: URL) throws {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
            try parseCentralDirectory()
        }

        init(data: Data) throws {
            self.data = data
            try parseCentralDirectory()
        }

        var names: [String] { Array(entries.keys) }

        func contains(_ name: String) -> Bool { entries[name] != nil }

        /// Decompressed bytes for `name`, or nil when the entry doesn't exist.
        func read(_ name: String) throws -> Data? {
            guard let entry = entries[name] else { return nil }
            let lh = entry.localHeaderOffset
            guard u32(lh) == 0x0403_4b50 else { throw ZipError.corrupt }
            let nameLen = Int(u16(lh + 26))
            let extraLen = Int(u16(lh + 28))
            let start = lh + 30 + nameLen + extraLen
            let end = start + entry.compressedSize
            guard end <= data.count, start >= 0 else { throw ZipError.corrupt }
            let slice = data.subdata(in: start..<end)
            switch entry.method {
            case 0:
                return slice
            case 8:
                do {
                    return try (slice as NSData).decompressed(using: .zlib) as Data
                } catch {
                    throw ZipError.corrupt
                }
            default:
                throw ZipError.unsupportedCompression(entry.method)
            }
        }

        private func parseCentralDirectory() throws {
            guard data.count >= 22 else { throw ZipError.notAZip }
            // End of central directory record: scan back at most 64 KB + 22.
            let minIndex = max(0, data.count - 65_557)
            var eocd = -1
            var i = data.count - 22
            while i >= minIndex {
                if u32(i) == 0x0605_4b50 { eocd = i; break }
                i -= 1
            }
            guard eocd >= 0 else { throw ZipError.notAZip }
            let entryCount = Int(u16(eocd + 10))
            var offset = Int(u32(eocd + 16))
            for _ in 0..<entryCount {
                guard offset + 46 <= data.count, u32(offset) == 0x0201_4b50 else { throw ZipError.corrupt }
                let method = Int(u16(offset + 10))
                let compressed = Int(u32(offset + 20))
                let uncompressed = Int(u32(offset + 24))
                let nameLen = Int(u16(offset + 28))
                let extraLen = Int(u16(offset + 30))
                let commentLen = Int(u16(offset + 32))
                let localOffset = Int(u32(offset + 42))
                let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
                let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
                entries[name] = Entry(
                    name: name,
                    method: method,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset
                )
                offset += 46 + nameLen + extraLen + commentLen
            }
        }

        private func u16(_ i: Int) -> UInt16 {
            UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
        }

        private func u32(_ i: Int) -> UInt32 {
            UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
        }
    }

    // MARK: - Writing

    final class Writer {
        private var body = Data()
        private var central = Data()
        private var count = 0

        init() {}

        /// Adds a stored entry. Names use forward slashes, no leading slash.
        func add(_ name: String, data: Data) {
            let nameBytes = Data(name.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(body.count)
            let (dosTime, dosDate) = Self.dosDateTime()

            // Local file header.
            body.append(le32(0x0403_4b50))
            body.append(le16(20))          // version needed
            body.append(le16(0x0800))      // flags: UTF-8 names
            body.append(le16(0))           // method: stored
            body.append(le16(dosTime))
            body.append(le16(dosDate))
            body.append(le32(crc))
            body.append(le32(UInt32(data.count)))
            body.append(le32(UInt32(data.count)))
            body.append(le16(UInt16(nameBytes.count)))
            body.append(le16(0))           // extra length
            body.append(nameBytes)
            body.append(data)

            // Central directory header.
            central.append(le32(0x0201_4b50))
            central.append(le16(20))       // version made by
            central.append(le16(20))       // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(UInt32(data.count)))
            central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))        // extra
            central.append(le16(0))        // comment
            central.append(le16(0))        // disk
            central.append(le16(0))        // internal attrs
            central.append(le32(0))        // external attrs
            central.append(le32(offset))
            central.append(nameBytes)
            count += 1
        }

        func finish() -> Data {
            var out = body
            let centralOffset = UInt32(out.count)
            out.append(central)
            out.append(le32(0x0605_4b50))
            out.append(le16(0))
            out.append(le16(0))
            out.append(le16(UInt16(count)))
            out.append(le16(UInt16(count)))
            out.append(le32(UInt32(central.count)))
            out.append(le32(centralOffset))
            out.append(le16(0))
            return out
        }

        private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
        private func le32(_ v: UInt32) -> Data {
            Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
        }

        private static func dosDateTime() -> (UInt16, UInt16) {
            let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: Date())
            let year = max(1980, c.year ?? 1980)
            let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
            let date = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
            return (time, date)
        }
    }

    // MARK: - CRC-32

    enum CRC32 {
        private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }

        static func checksum(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                for byte in buffer {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
    }
}

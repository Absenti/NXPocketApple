import Foundation

/// The CodeDirectory of a Mach-O code signature: who signed it, for which team, and how.
/// Every field of an embedded signature is big-endian, whatever the CPU.
public struct CodeSignatureInfo: Equatable, Sendable {
    public static let codeDirectoryMagic: UInt32 = 0xfade_0c02
    public static let superBlobMagic: UInt32 = 0xfade_0cc0
    public static let cmsWrapperMagic: UInt32 = 0xfade_0b01
    public static let adHocFlag: UInt32 = 0x2
    public static let hardFlag: UInt32 = 0x100
    public static let killFlag: UInt32 = 0x200

    public var identifier: String
    public var teamID: String?
    public var flags: UInt32
    /// The CMS blob carries a certificate, so the signature names a real signer.
    public var hasCertificate: Bool
    public var signerName: String?
    public var codeDirectoryVersion: UInt32
    public var hashType: UInt8

    public var isAdHoc: Bool { flags & Self.adHocFlag != 0 || !hasCertificate }
    public var isHardened: Bool { flags & Self.hardFlag != 0 }

    public init(identifier: String, teamID: String?, flags: UInt32, hasCertificate: Bool,
                signerName: String?, codeDirectoryVersion: UInt32, hashType: UInt8) {
        self.identifier = identifier
        self.teamID = teamID
        self.flags = flags
        self.hasCertificate = hasCertificate
        self.signerName = signerName
        self.codeDirectoryVersion = codeDirectoryVersion
        self.hashType = hashType
    }

    /// Reads the signature of `image`, or nil when the Mach-O carries none.
    public static func read(_ image: MachOFile, path: String = "") throws -> CodeSignatureInfo? {
        guard let location = image.codeSignature else { return nil }
        let data = image.data
        let offset = Int(location.offset), size = Int(location.size)
        guard offset > 0, size >= 12, offset + size <= data.count else {
            throw NXPocketError(.notSigned, "LC_CODE_SIGNATURE points outside the file", path: path)
        }
        let reader = Reader(data)
        let base = offset
        guard reader.be32(base) == superBlobMagic else {
            throw NXPocketError(.notSigned, "no code signature superblob", path: path)
        }
        let count = Int(reader.be32(base + 8))
        var info: CodeSignatureInfo?
        var hasCertificate = false
        var signerName: String?

        for index in 0..<count {
            let entry = base + 12 + index * 8
            guard entry + 8 <= base + size else { break }
            let type = reader.be32(entry)
            let blobOffset = Int(reader.be32(entry + 4))
            guard blobOffset + 8 <= size else { continue }
            let blob = base + blobOffset
            let magic = reader.be32(blob), length = Int(reader.be32(blob + 4))
            guard length >= 8, blobOffset + length <= size else { continue }

            if magic == codeDirectoryMagic, type == 0 {
                let version = reader.be32(blob + 8)
                let flags = reader.be32(blob + 12)
                let identifierOffset = Int(reader.be32(blob + 20))
                let teamOffset = version >= 0x20200 ? Int(reader.be32(blob + 48)) : 0
                let identifier = identifierOffset < length
                    ? reader.cString(at: blob + identifierOffset, limitedTo: length - identifierOffset) ?? "" : ""
                let team = teamOffset > 0 && teamOffset < length
                    ? reader.cString(at: blob + teamOffset, limitedTo: length - teamOffset) : nil
                info = CodeSignatureInfo(identifier: identifier, teamID: team, flags: flags,
                                         hasCertificate: false, signerName: nil,
                                         codeDirectoryVersion: version, hashType: reader.u8(blob + 37))
            } else if magic == cmsWrapperMagic {
                hasCertificate = length > 8
                if hasCertificate { signerName = knownName(in: data, from: blob, length: length) }
            }
        }

        guard var result = info else {
            throw NXPocketError(.notSigned, "the signature has no CodeDirectory", path: path)
        }
        result.hasCertificate = hasCertificate
        result.signerName = signerName
        return result
    }

    /// The printable certificate name inside the CMS blob: the first known Apple subject prefix that appears.
    static func knownName(in data: Data, from offset: Int, length: Int) -> String? {
        let prefixes = ["Apple Development", "iPhone Developer", "Apple Distribution", "iPhone Distribution",
                        "Developer ID Application", "Mac Developer"]
        let end = min(offset + length, data.count)
        guard offset < end else { return nil }
        let haystack = [UInt8](data[data.startIndex + offset..<data.startIndex + end])
        for prefix in prefixes {
            let needle = Array(prefix.utf8)
            guard haystack.count >= needle.count else { continue }
            for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
                var stop = start
                while stop < haystack.count, stop - start < 80, haystack[stop] >= 0x20, haystack[stop] < 0x7F { stop += 1 }
                return String(bytes: haystack[start..<stop], encoding: .ascii)
            }
        }
        return nil
    }
}

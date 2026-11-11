import CommonCrypto
import Foundation

/// The three AES modes a Switch package uses, over CommonCrypto's ECB: what the launcher reads is a few kilobytes
/// per package (headers, a content meta, a control file), so building CTR and XTS on single blocks costs nothing
/// and keeps the code free of a crypto dependency.
enum SwitchCrypto {
    /// AES-128 in ECB over whole 16-byte blocks, without padding.
    static func ecb(_ data: [UInt8], key: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard data.count % 16 == 0, key.count == 16 else {
            throw SwitchFormatError("AES needs 16-byte blocks and a 16-byte key")
        }
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode), key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved == data.count else { throw SwitchFormatError("AES failed (\(status))") }
        return out
    }

    /// AES-128-CTR. `counter` is the counter block of the first 16 bytes of `data`; it counts up as a 128-bit
    /// big-endian number, which for an NCA section is its fixed upper half and the offset / 16 in the lower half.
    static func ctr(_ data: [UInt8], key: [UInt8], counter: [UInt8]) throws -> [UInt8] {
        guard counter.count == 16 else { throw SwitchFormatError("an AES-CTR counter is 16 bytes") }
        let blocks = (data.count + 15) / 16
        var stream = [UInt8](repeating: 0, count: blocks * 16)
        var block = counter
        for index in 0..<blocks {
            stream.replaceSubrange(index * 16..<index * 16 + 16, with: block)
            increment(&block)
        }
        let keystream = try ecb(stream, key: key, encrypt: true)
        var out = data
        for index in out.indices { out[index] ^= keystream[index] }
        return out
    }

    static func increment(_ counter: inout [UInt8]) {
        var index = counter.count - 1
        while index >= 0 {
            counter[index] &+= 1
            if counter[index] != 0 { return }
            index -= 1
        }
    }

    /// Nintendo's AES-128-XTS, which an NCA header is encrypted with: 0x200-byte sectors, and, unlike IEEE P1619,
    /// the sector number goes into the tweak big-endian. `key` is 32 bytes: the data key, then the tweak key.
    static func xtsDecrypt(_ data: [UInt8], key: [UInt8], firstSector: UInt64, sectorSize: Int = 0x200) throws -> [UInt8] {
        guard key.count == 32, sectorSize > 0, sectorSize % 16 == 0, data.count % sectorSize == 0 else {
            throw SwitchFormatError("AES-XTS needs whole sectors and a 32-byte key")
        }
        let dataKey = Array(key[0..<16])
        let tweakKey = Array(key[16..<32])
        var out = [UInt8](repeating: 0, count: data.count)
        for sector in 0..<(data.count / sectorSize) {
            var tweak = [UInt8](repeating: 0, count: 16)
            var number = firstSector &+ UInt64(sector)
            for index in stride(from: 15, through: 8, by: -1) {
                tweak[index] = UInt8(number & 0xFF)
                number >>= 8
            }
            tweak = try ecb(tweak, key: tweakKey, encrypt: true)
            let start = sector * sectorSize
            var masks = [UInt8](repeating: 0, count: sectorSize)
            var masked = [UInt8](repeating: 0, count: sectorSize)
            for block in 0..<(sectorSize / 16) {
                for index in 0..<16 {
                    masks[block * 16 + index] = tweak[index]
                    masked[block * 16 + index] = data[start + block * 16 + index] ^ tweak[index]
                }
                multiplyByAlpha(&tweak)
            }
            let plain = try ecb(masked, key: dataKey, encrypt: false)
            for index in 0..<sectorSize { out[start + index] = plain[index] ^ masks[index] }
        }
        return out
    }

    /// The inverse, for the tests: they build an encrypted header byte by byte, with a key made up on the spot.
    static func xtsEncrypt(_ data: [UInt8], key: [UInt8], firstSector: UInt64, sectorSize: Int = 0x200) throws -> [UInt8] {
        guard key.count == 32, sectorSize > 0, sectorSize % 16 == 0, data.count % sectorSize == 0 else {
            throw SwitchFormatError("AES-XTS needs whole sectors and a 32-byte key")
        }
        let dataKey = Array(key[0..<16])
        let tweakKey = Array(key[16..<32])
        var out = [UInt8](repeating: 0, count: data.count)
        for sector in 0..<(data.count / sectorSize) {
            var tweak = [UInt8](repeating: 0, count: 16)
            var number = firstSector &+ UInt64(sector)
            for index in stride(from: 15, through: 8, by: -1) {
                tweak[index] = UInt8(number & 0xFF)
                number >>= 8
            }
            tweak = try ecb(tweak, key: tweakKey, encrypt: true)
            let start = sector * sectorSize
            var masks = [UInt8](repeating: 0, count: sectorSize)
            var masked = [UInt8](repeating: 0, count: sectorSize)
            for block in 0..<(sectorSize / 16) {
                for index in 0..<16 {
                    masks[block * 16 + index] = tweak[index]
                    masked[block * 16 + index] = data[start + block * 16 + index] ^ tweak[index]
                }
                multiplyByAlpha(&tweak)
            }
            let cipher = try ecb(masked, key: dataKey, encrypt: true)
            for index in 0..<sectorSize { out[start + index] = cipher[index] ^ masks[index] }
        }
        return out
    }

    /// The tweak of the next block: multiplication by x in GF(2^128), little-endian, as XTS defines it.
    private static func multiplyByAlpha(_ tweak: inout [UInt8]) {
        let carry = tweak[15] >> 7
        for index in stride(from: 15, to: 0, by: -1) {
            tweak[index] = tweak[index] << 1 | tweak[index - 1] >> 7
        }
        tweak[0] <<= 1
        if carry != 0 { tweak[0] ^= 0x87 }
    }
}

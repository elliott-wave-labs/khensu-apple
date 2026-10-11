// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// BIP-350 bech32m, used for `khensu1...` addresses (PROTOCOL.md 3.1).
public enum Bech32m {
    public static let khensuHRP = "khensu"

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let constant: UInt32 = 0x2bc8_30a3
    private static let reverse: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in charset.enumerated() { map[c] = UInt8(i) }
        return map
    }()

    public static func encode(hrp: String, data: Data) -> String {
        let values = convertBits(Array(data), from: 8, to: 5, pad: true)!
        let checksum = createChecksum(hrp: hrp, values: values)
        return hrp + "1" + String((values + checksum).map { charset[Int($0)] })
    }

    public static func decode(_ string: String) -> (hrp: String, data: Data)? {
        guard string.count <= 1023,
              string == string.lowercased() || string == string.uppercased()
        else { return nil }
        let s = string.lowercased()
        guard let sep = s.lastIndex(of: "1") else { return nil }
        let hrp = String(s[..<sep])
        let rest = s[s.index(after: sep)...]
        guard !hrp.isEmpty, rest.count >= 6,
              hrp.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
        else { return nil }
        var values: [UInt8] = []
        for c in rest {
            guard let v = reverse[c] else { return nil }
            values.append(v)
        }
        guard polymod(hrpExpand(hrp) + values) == constant else { return nil }
        guard let bytes = convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (hrp, Data(bytes))
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ff_ffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 {
                chk ^= gen[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let mod = polymod(hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ constant
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0, bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        for value in data {
            guard Int(value) >> from == 0 else { return nil }
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || (acc << (to - bits)) & maxv != 0 {
            return nil
        }
        return out
    }
}

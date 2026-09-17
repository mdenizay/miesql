import Foundation
import NIOCore
import PostgresNIO

/// PostgresNIO asks the server for results in the binary wire format, so every value has
/// to be decoded here before it can be shown. Types we do not know how to decode fall back
/// to a hex dump rather than being silently dropped.
enum PostgresValueRenderer {

    static func render(bytes: ByteBuffer?, dataType: PostgresDataType, format: PostgresFormat) -> SQLValue {
        guard var buffer = bytes else { return .null }
        let raw = buffer.readBytes(length: buffer.readableBytes) ?? []

        if format == .text {
            return .text(String(decoding: raw, as: UTF8.self))
        }
        return .text(decodeBinary(raw, oid: dataType.rawValue))
    }

    // MARK: - Binary decoding

    static func decodeBinary(_ bytes: [UInt8], oid: UInt32) -> String {
        switch oid {
        case 16: // bool
            return (bytes.first ?? 0) != 0 ? "true" : "false"

        case 17: // bytea
            return "\\x" + hex(bytes)

        case 18, 19, 25, 1042, 1043, 114, 142, 705, 1790, 2205, 3220, 3361, 3402, 4072:
            // char, name, text, bpchar, varchar, json, xml, unknown and friends are UTF-8.
            return String(decoding: bytes, as: UTF8.self)

        case 3802: // jsonb — one leading version byte
            return String(decoding: bytes.dropFirst(), as: UTF8.self)

        case 21: return String(readInt16(bytes, 0))
        case 23, 26, 24, 2202, 2203, 2204, 2206, 3734, 3769: return String(readInt32(bytes, 0))
        case 20: return String(readInt64(bytes, 0))

        case 700: return formatDouble(Double(Float(bitPattern: UInt32(bitPattern: readInt32(bytes, 0)))))
        case 701: return formatDouble(Double(bitPattern: UInt64(bitPattern: readInt64(bytes, 0))))

        case 1700: return decodeNumeric(bytes)
        case 790: return decodeMoney(bytes)

        case 2950: return decodeUUID(bytes)

        case 1082: return decodeDate(bytes)
        case 1083: return decodeTime(micros: readInt64(bytes, 0))
        case 1266: return decodeTimeTZ(bytes)
        case 1114: return decodeTimestamp(bytes, withZone: false)
        case 1184: return decodeTimestamp(bytes, withZone: true)
        case 1186: return decodeInterval(bytes)

        case 1560, 1562: return decodeBitString(bytes)

        case 869, 650: return decodeInet(bytes)
        case 829, 774: return decodeMacAddress(bytes)

        case 600: // point
            guard bytes.count >= 16 else { return hex(bytes) }
            let x = Double(bitPattern: UInt64(bitPattern: readInt64(bytes, 0)))
            let y = Double(bitPattern: UInt64(bitPattern: readInt64(bytes, 8)))
            return "(\(formatDouble(x)),\(formatDouble(y)))"

        default:
            if isArrayOID(oid) {
                return decodeArray(bytes)
            }
            // User-defined types — enums and domains over text — arrive as their text form.
            if oid >= 16384 {
                return String(decoding: bytes, as: UTF8.self)
            }
            return "\\x" + hex(bytes)
        }
    }

    // MARK: - Composite types

    private static func decodeArray(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 12 else { return "{}" }
        let dimensions = Int(readInt32(bytes, 0))
        let elementOID = UInt32(bitPattern: readInt32(bytes, 8))
        guard dimensions > 0 else { return "{}" }

        var offset = 12
        var dimensionSizes: [Int] = []
        for _ in 0..<dimensions {
            guard offset + 8 <= bytes.count else { return "{}" }
            dimensionSizes.append(Int(readInt32(bytes, offset)))
            offset += 8 // size + lower bound
        }

        func readElements(_ count: Int) -> [String] {
            var values: [String] = []
            for _ in 0..<count {
                guard offset + 4 <= bytes.count else { break }
                let length = Int(readInt32(bytes, offset))
                offset += 4
                if length < 0 {
                    values.append("NULL")
                    continue
                }
                guard offset + length <= bytes.count else { break }
                let slice = Array(bytes[offset..<(offset + length)])
                offset += length
                values.append(quoteArrayElement(decodeBinary(slice, oid: elementOID), oid: elementOID))
            }
            return values
        }

        // Nested dimensions are rendered by slicing the flat element list back into shape.
        func build(_ level: Int) -> String {
            if level == dimensions - 1 {
                return "{" + readElements(dimensionSizes[level]).joined(separator: ",") + "}"
            }
            var parts: [String] = []
            for _ in 0..<dimensionSizes[level] {
                parts.append(build(level + 1))
            }
            return "{" + parts.joined(separator: ",") + "}"
        }

        return build(0)
    }

    private static func quoteArrayElement(_ value: String, oid: UInt32) -> String {
        if value == "NULL" { return value }
        let needsQuotes = value.isEmpty
            || value.contains(where: { $0 == "," || $0 == "{" || $0 == "}" || $0 == "\"" || $0 == "\\" || $0.isWhitespace })
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func isArrayOID(_ oid: UInt32) -> Bool {
        // The built-in array types occupy a handful of well-known ranges.
        let arrayOIDs: Set<UInt32> = [
            143, 199, 629, 651, 719, 775, 791, 1000, 1001, 1002, 1003, 1005, 1006, 1007,
            1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017, 1018, 1019, 1020,
            1021, 1022, 1027, 1028, 1034, 1040, 1041, 1115, 1182, 1183, 1185, 1187, 1231,
            1263, 1270, 1561, 1563, 2201, 2207, 2208, 2209, 2210, 2211, 2949, 2951, 3643,
            3644, 3645, 3735, 3770, 3807, 3905, 3907, 3909, 3911, 3913, 3927, 4090
        ]
        return arrayOIDs.contains(oid)
    }

    // MARK: - Numerics

    private static func decodeNumeric(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 8 else { return "0" }
        let digitCount = Int(readUInt16(bytes, 0))
        let weight = Int(readInt16(bytes, 2))
        let sign = readUInt16(bytes, 4)
        let scale = Int(readUInt16(bytes, 6))

        if sign == 0xC000 { return "NaN" }
        if sign == 0xD000 { return "Infinity" }
        if sign == 0xF000 { return "-Infinity" }

        var digits: [Int] = []
        for i in 0..<digitCount {
            let offset = 8 + i * 2
            guard offset + 2 <= bytes.count else { break }
            digits.append(Int(readUInt16(bytes, offset)))
        }

        // Digits are base-10000 groups; `weight` is the index of the last integral group.
        var integerPart = ""
        if weight < 0 {
            integerPart = "0"
        } else {
            for i in 0...weight {
                let group = i < digits.count ? digits[i] : 0
                integerPart += i == 0 ? String(group) : String(format: "%04d", group)
            }
        }

        var fractionPart = ""
        var index = weight + 1
        while fractionPart.count < scale {
            let group = (index >= 0 && index < digits.count) ? digits[index] : 0
            fractionPart += String(format: "%04d", group)
            index += 1
        }
        if fractionPart.count > scale {
            fractionPart = String(fractionPart.prefix(scale))
        }

        let signPrefix = sign == 0x4000 ? "-" : ""
        return scale > 0 ? "\(signPrefix)\(integerPart).\(fractionPart)" : "\(signPrefix)\(integerPart)"
    }

    private static func decodeMoney(_ bytes: [UInt8]) -> String {
        let cents = readInt64(bytes, 0)
        let value = Double(cents) / 100.0
        return String(format: "%.2f", value)
    }

    private static func formatDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - Dates and times

    /// PostgreSQL counts from 2000-01-01 rather than the Unix epoch.
    private static let postgresEpoch: TimeInterval = 946_684_800

    private static func decodeDate(_ bytes: [UInt8]) -> String {
        let days = Int(readInt32(bytes, 0))
        let date = Date(timeIntervalSince1970: postgresEpoch + Double(days) * 86_400)
        return dateFormatter.string(from: date)
    }

    private static func decodeTimestamp(_ bytes: [UInt8], withZone: Bool) -> String {
        let micros = readInt64(bytes, 0)
        // "infinity" and "-infinity" are represented by the extremes of the range.
        if micros == Int64.max { return "infinity" }
        if micros == Int64.min { return "-infinity" }
        let seconds = Double(micros) / 1_000_000
        let date = Date(timeIntervalSince1970: postgresEpoch + seconds)
        let fractional = abs(micros % 1_000_000)
        var text = (withZone ? timestampTZFormatter : timestampFormatter).string(from: date)
        if fractional != 0 {
            let fraction = String(format: "%06d", fractional)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            // Insert the fraction before the zone suffix, if any.
            if withZone, let plus = text.lastIndex(where: { $0 == "+" || $0 == "-" }), plus > text.startIndex {
                text.insert(contentsOf: ".\(fraction)", at: plus)
            } else {
                text += ".\(fraction)"
            }
        }
        return text
    }

    private static func decodeTime(micros: Int64) -> String {
        let totalSeconds = micros / 1_000_000
        let fraction = micros % 1_000_000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        var text = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        if fraction != 0 {
            let fractionText = String(format: "%06d", fraction)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            text += ".\(fractionText)"
        }
        return text
    }

    private static func decodeTimeTZ(_ bytes: [UInt8]) -> String {
        let time = decodeTime(micros: readInt64(bytes, 0))
        // The stored offset is seconds *west* of UTC, so the displayed sign is inverted.
        let offsetSeconds = -Int(readInt32(bytes, 8))
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absolute = abs(offsetSeconds)
        return time + String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }

    private static func decodeInterval(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 16 else { return "00:00:00" }
        let micros = readInt64(bytes, 0)
        let days = Int(readInt32(bytes, 8))
        let months = Int(readInt32(bytes, 12))

        var parts: [String] = []
        if months != 0 {
            let years = months / 12
            let remainingMonths = months % 12
            if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
            if remainingMonths != 0 { parts.append("\(remainingMonths) mon\(abs(remainingMonths) == 1 ? "" : "s")") }
        }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty {
            let negative = micros < 0
            let time = decodeTime(micros: abs(micros))
            parts.append(negative ? "-\(time)" : time)
        }
        return parts.joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = makeFormatter("yyyy-MM-dd", utc: true)
    private static let timestampFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm:ss", utc: true)
    private static let timestampTZFormatter: DateFormatter = makeFormatter("yyyy-MM-dd HH:mm:ssZZZZZ", utc: false)

    private static func makeFormatter(_ format: String, utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        // `timestamp` has no zone, so it must be rendered exactly as stored.
        formatter.timeZone = utc ? TimeZone(secondsFromGMT: 0) : TimeZone.current
        return formatter
    }

    // MARK: - Odds and ends

    private static func decodeUUID(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 16 else { return hex(bytes) }
        let hexString = hex(Array(bytes.prefix(16)))
        let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        let characters = Array(hexString)
        return ranges.map { String(characters[$0]) }.joined(separator: "-")
    }

    private static func decodeBitString(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 4 else { return "" }
        let bitCount = Int(readInt32(bytes, 0))
        var output = ""
        for bit in 0..<bitCount {
            let byteIndex = 4 + bit / 8
            guard byteIndex < bytes.count else { break }
            let mask: UInt8 = 0x80 >> UInt8(bit % 8)
            output.append((bytes[byteIndex] & mask) != 0 ? "1" : "0")
        }
        return output
    }

    private static func decodeInet(_ bytes: [UInt8]) -> String {
        // family, bits, is_cidr, address length, then the address itself.
        guard bytes.count >= 4 else { return hex(bytes) }
        let family = bytes[0]
        let bits = Int(bytes[1])
        let length = Int(bytes[3])
        let address = Array(bytes.dropFirst(4).prefix(length))

        if family == 2, address.count == 4 {
            let text = address.map(String.init).joined(separator: ".")
            return bits == 32 ? text : "\(text)/\(bits)"
        }
        if address.count == 16 {
            var groups: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                groups.append(String(format: "%x", Int(address[i]) << 8 | Int(address[i + 1])))
            }
            let text = groups.joined(separator: ":")
            return bits == 128 ? text : "\(text)/\(bits)"
        }
        return hex(bytes)
    }

    private static func decodeMacAddress(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Big-endian readers

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readInt16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(bytes, offset))
    }

    private static func readInt32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        guard offset + 4 <= bytes.count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 { value = value << 8 | UInt32(bytes[offset + i]) }
        return Int32(bitPattern: value)
    }

    private static func readInt64(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        guard offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(bytes[offset + i]) }
        return Int64(bitPattern: value)
    }
}

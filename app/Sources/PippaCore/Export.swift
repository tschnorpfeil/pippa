import Foundation

/// ZIP without compression ("stored"), with CRC-32. Enough for XLSX.
public struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, dayOfMonth: Int = c.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dayBits: Int = (year << 9) | (month << 5) | dayOfMonth
        let time = UInt16(timeBits)
        let day = UInt16(dayBits)
        return (time, day)
    }

    public mutating func add(_ name: String, _ data: Data, date: Date = Date()) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(data)
        let (time, day) = Self.dosDateTime(date)
        let offset = UInt32(body.count)
        var local = Data()
        local += Self.le32(0x0403_4B50); local += Self.le16(20); local += Self.le16(0x0800); local += Self.le16(0)
        local += Self.le16(time); local += Self.le16(day); local += Self.le32(crc)
        local += Self.le32(UInt32(data.count)); local += Self.le32(UInt32(data.count))
        local += Self.le16(UInt16(nameData.count)); local += Self.le16(0)
        body += local; body += nameData; body += data

        var entry = Data()
        entry += Self.le32(0x0201_4B50); entry += Self.le16(20); entry += Self.le16(20); entry += Self.le16(0x0800); entry += Self.le16(0)
        entry += Self.le16(time); entry += Self.le16(day); entry += Self.le32(crc)
        entry += Self.le32(UInt32(data.count)); entry += Self.le32(UInt32(data.count))
        entry += Self.le16(UInt16(nameData.count)); entry += Self.le16(0); entry += Self.le16(0)
        entry += Self.le16(0); entry += Self.le16(0); entry += Self.le32(0); entry += Self.le32(offset)
        central += entry; central += nameData
        count += 1
    }

    public func finish() -> Data {
        var out = body
        out += central
        out += Self.le32(0x0605_4B50); out += Self.le16(0); out += Self.le16(0)
        out += Self.le16(count); out += Self.le16(count)
        out += Self.le32(UInt32(central.count)); out += Self.le32(UInt32(body.count)); out += Self.le16(0)
        return out
    }
}

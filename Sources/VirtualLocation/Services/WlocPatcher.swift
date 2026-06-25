import Foundation
import zlib

private func debugLog(_ msg: String) {
    try? FileHandle.standardError.write(contentsOf: Data("[WLOC] \(msg)\n".utf8))
}

// MARK: - Protobuf Wire Format Helpers

struct WlocStats {
    var wifi = 0
    var cell = 0
    var locations = 0
    var skipped = 0
    var gzip = false
}

func isWlocHost(_ host: String) -> Bool {
    let h = host.lowercased()
    return h == "gs-loc.apple.com" || h == "gs-loc-cn.apple.com"
}

private func readVarint(_ data: Data, offset: Int) throws -> (value: UInt64, newOffset: Int) {
    let count = data.count
    guard offset >= 0, offset < count else { throw WlocError.truncatedVarint }
    var value: UInt64 = 0
    var mul: UInt64 = 1
    var shift = 0
    var off = offset
    return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        guard let base = ptr.baseAddress else { throw WlocError.truncatedVarint }
        while off < count {
            let b = UInt64(base.load(fromByteOffset: off, as: UInt8.self))
            off += 1
            value += (b & 127) &* mul
            if (b & 128) == 0 { return (value, off) }
            mul &*= 128
            shift += 7
            if shift >= 63 { throw WlocError.varintTooLong }
        }
        throw WlocError.truncatedVarint
    }
}

private func writeVarint(_ value: UInt64) -> Data {
    var v = value
    var out = Data()
    while v >= 128 {
        out.append(UInt8(v % 128) | 128)
        v /= 128
    }
    out.append(UInt8(v))
    return out
}

private struct ProtoField {
    let fieldNo: Int
    let wireType: Int
    let value: Data
    let raw: Data
}

private func parseFields(_ data: Data) throws -> [ProtoField] {
    let bytes = [UInt8](data)
    let count = bytes.count
    var offset = 0
    var fields: [ProtoField] = []
    while offset < count {
        let start = offset
        let (tag, newOff) = try readVarint(data, offset: offset)
        offset = newOff
        let fieldNo = Int(tag / 8)
        let wireType = Int(tag & 7)
        guard fieldNo != 0 else { throw WlocError.invalidFieldZero }

        let valueStart = offset
        let rawValue: [UInt8]
        switch wireType {
        case 0:
            let (v, nextOff) = try readVarint(data, offset: offset)
            offset = nextOff
            rawValue = [UInt8](writeVarint(v))
        case 1:
            guard offset + 8 <= count else { throw WlocError.truncatedVarint }
            rawValue = Array(bytes[offset..<offset + 8])
            offset += 8
        case 2:
            let (len, nextOff) = try readVarint(data, offset: offset)
            let (end, didOverflow) = nextOff.addingReportingOverflow(Int(len))
            guard !didOverflow, end <= count else { throw WlocError.truncatedVarint }
            offset = nextOff
            guard offset <= end else { throw WlocError.truncatedVarint }
            rawValue = Array(bytes[offset..<end])
            offset = end
        case 5:
            guard offset + 4 <= count else { throw WlocError.truncatedVarint }
            rawValue = Array(bytes[offset..<offset + 4])
            offset += 4
        default:
            throw WlocError.unsupportedWireType(wireType)
        }

        fields.append(ProtoField(
            fieldNo: fieldNo,
            wireType: wireType,
            value: Data(rawValue),
            raw: Data(bytes[start..<offset])
        ))
    }
    return fields
}

private func encodeField(fieldNo: Int, wireType: Int, value: Data) -> Data {
    let head = writeVarint(UInt64(fieldNo * 8 + wireType))
    switch wireType {
    case 0:
        return head + value
    case 1, 5:
        return head + value
    case 2:
        return head + writeVarint(UInt64(value.count)) + value
    default:
        return head + value
    }
}

// MARK: - Location Patching

private func patchLocationMessage(_ data: Data, stats: inout WlocStats, lat: Double, lng: Double, accuracy: Int) throws -> Data {
    let fields = try parseFields(data)
    var hasLat = false
    var hasLon = false
    for f in fields {
        if f.fieldNo == 1 && f.wireType == 0 { hasLat = true }
        if f.fieldNo == 2 && f.wireType == 0 { hasLon = true }
    }
    guard hasLat && hasLon else { return data }

    let latInt = UInt64(bitPattern: Int64(round(lat * 100_000_000)))
    let lngInt = UInt64(bitPattern: Int64(round(lng * 100_000_000)))

    var parts = Data()
    for f in fields {
        if f.fieldNo == 1 && f.wireType == 0 {
            parts += encodeField(fieldNo: 1, wireType: 0, value: writeVarint(latInt))
        } else if f.fieldNo == 2 && f.wireType == 0 {
            parts += encodeField(fieldNo: 2, wireType: 0, value: writeVarint(lngInt))
        } else if f.fieldNo == 3 && f.wireType == 0 {
            parts += encodeField(fieldNo: 3, wireType: 0, value: writeVarint(UInt64(accuracy)))
        } else {
            parts += f.raw
        }
    }
    stats.locations += 1
    return parts
}

private func patchWifiDevice(_ data: Data, stats: inout WlocStats, lat: Double, lng: Double, accuracy: Int) throws -> Data {
    let fields = try parseFields(data)

    var looksLikeWifi = false
    for f in fields {
        if f.fieldNo == 1 && f.wireType == 2 {
            if let s = String(data: f.value, encoding: .utf8) {
                let macRegex = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$")
                looksLikeWifi = macRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
        }
    }
    guard looksLikeWifi else { return data }

    var changed = false
    var parts = Data()
    for f in fields {
        if f.fieldNo == 2 && f.wireType == 2 {
            do {
                let original = f.value
                let patched = try patchLocationMessage(original, stats: &stats, lat: lat, lng: lng, accuracy: accuracy)
                if patched != original { changed = true }
                parts += encodeField(fieldNo: f.fieldNo, wireType: f.wireType, value: patched)
            } catch {
                stats.skipped += 1
                parts += f.raw
            }
        } else {
            parts += f.raw
        }
    }
    if changed { stats.wifi += 1 }
    return parts
}

private func patchCellTower(_ data: Data, stats: inout WlocStats, lat: Double, lng: Double, accuracy: Int) throws -> Data {
    let fields = try parseFields(data)
    var changed = false
    var parts = Data()
    for f in fields {
        if f.fieldNo == 5 && f.wireType == 2 {
            do {
                let original = f.value
                let patched = try patchLocationMessage(original, stats: &stats, lat: lat, lng: lng, accuracy: accuracy)
                if patched != original { changed = true }
                parts += encodeField(fieldNo: f.fieldNo, wireType: f.wireType, value: patched)
            } catch {
                stats.skipped += 1
                parts += f.raw
            }
        } else {
            parts += f.raw
        }
    }
    if changed { stats.cell += 1 }
    return parts
}

private func patchPayload(_ data: Data, stats: inout WlocStats, lat: Double, lng: Double, accuracy: Int) throws -> Data {
    let fields = try parseFields(data)
    var parts = Data()
    var wifiCount = 0
    var cellCount = 0
    for f in fields {
        if f.wireType == 2 && f.fieldNo == 2 {
            wifiCount += 1
            let patched = try patchWifiDevice(f.value, stats: &stats, lat: lat, lng: lng, accuracy: accuracy)
            parts += encodeField(fieldNo: f.fieldNo, wireType: f.wireType, value: patched)
        } else if f.wireType == 2 && (f.fieldNo == 22 || f.fieldNo == 24) {
            cellCount += 1
            let patched = try patchCellTower(f.value, stats: &stats, lat: lat, lng: lng, accuracy: accuracy)
            parts += encodeField(fieldNo: f.fieldNo, wireType: f.wireType, value: patched)
        } else {
            parts += f.raw
        }
    }
    return parts
}

private func patchFrame(_ data: Data, stats: inout WlocStats, lat: Double, lng: Double, accuracy: Int) throws -> Data {
    guard data.count >= 10 else {
        debugLog("frameTooShort: \(data.count)")
        throw WlocError.frameTooShort(data.count)
    }

    let payloadLen = Int(data[8]) << 8 | Int(data[9])
    guard payloadLen >= 0, payloadLen <= 65535, payloadLen + 10 <= data.count else {
        debugLog("invalidFrameLength: \(payloadLen) for data.count=\(data.count)")
        throw WlocError.invalidFrameLength(payloadLen, data.count)
    }

    let prefix = data[0..<8]
    let payload = data[10..<10 + payloadLen]
    let suffix = data.suffix(from: 10 + payloadLen)

    let patchedPayload = try patchPayload(payload, stats: &stats, lat: lat, lng: lng, accuracy: accuracy)
    guard patchedPayload.count <= 65535 else {
        throw WlocError.patchedPayloadTooLarge(patchedPayload.count)
    }

    var result = Data()
    result += prefix
    result.append(UInt8((patchedPayload.count >> 8) & 255))
    result.append(UInt8(patchedPayload.count & 255))
    result += patchedPayload
    result += Data(suffix)
    return result
}

// MARK: - Gzip Decompression

private func isGzipped(_ data: Data) -> Bool {
    data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B
}

private func gunzip(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { src in
        guard let srcPtr = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw WlocError.gzipDecompressFailed
        }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        stream.next_in = UnsafeMutablePointer(mutating: srcPtr)
        stream.avail_in = uInt(data.count)

        let initResult = inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw WlocError.gzipDecompressFailed }
        defer { inflateEnd(&stream) }

        var output = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        repeat {
            stream.next_out = UnsafeMutablePointer(mutating: buffer)
            stream.avail_out = uInt(bufferSize)

            let result = inflate(&stream, Z_NO_FLUSH)
            guard result != Z_STREAM_ERROR else { throw WlocError.gzipDecompressFailed }

            let count = bufferSize - Int(stream.avail_out)
            if count > 0 {
                output.append(buffer, count: count)
            }
        } while stream.avail_out == 0

        return output
    }
}

// MARK: - Public API

enum WlocError: Error, LocalizedError {
    case varintTooLong
    case truncatedVarint
    case invalidFieldZero
    case unsupportedWireType(Int)
    case frameTooShort(Int)
    case invalidFrameLength(Int, Int)
    case patchedPayloadTooLarge(Int)
    case gzipDecompressFailed

    var errorDescription: String? {
        switch self {
        case .varintTooLong:        return "varint is too long"
        case .truncatedVarint:      return "truncated varint or data out of bounds"
        case .invalidFieldZero:     return "invalid protobuf field 0"
        case .unsupportedWireType(let t): return "unsupported wire type \(t)"
        case .frameTooShort(let l): return "body too short: \(l)"
        case .invalidFrameLength(let p, let t): return "invalid frame length \(p) for \(t)"
        case .patchedPayloadTooLarge(let l): return "patched payload too large: \(l)"
        case .gzipDecompressFailed: return "gzip decompress failed"
        }
    }
}

func patchWlocResponse(_ data: Data, latitude: Double, longitude: Double, accuracy: Int = 25) throws -> (patched: Data, stats: WlocStats) {
    var stats = WlocStats()

    let workingData: Data
    if isGzipped(data) {
        workingData = try gunzip(data)
        stats.gzip = true
    } else {
        workingData = data
    }

    let patched = try patchFrame(workingData, stats: &stats, lat: latitude, lng: longitude, accuracy: accuracy)
    debugLog("修补完成: wifi:\(stats.wifi) cell:\(stats.cell) locations:\(stats.locations) skipped:\(stats.skipped)")
    return (patched, stats)
}

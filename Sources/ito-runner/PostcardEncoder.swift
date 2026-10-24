import Foundation

/// A custom Encoder that encodes Swift `Encodable` types into the Postcard binary format.
/// Postcard is a #![no_std] focused serialization format used heavily in Rust ecosystems.
public struct ItoPostcardEncoder: Sendable {

    /// The plugin ABI whose layouts to write (`ItoRunner.supportedABIVersions`).
    public let abiVersion: Int

    public init(abiVersion: Int = ItoRunner.supportedABIVersions.upperBound) {
        self.abiVersion = abiVersion
    }

    /// Encodes the given value into a Postcard-formatted byte array.
    /// - Parameter value: The value to encode.
    /// - Returns: The Postcard binary representation.
    /// - Throws: `ItoError.postcardEncodingError` if encoding fails.
    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = _PostcardEncoder()
        encoder.userInfo[postcardABIVersionKey] = abiVersion

        if let map = value as? PostcardMapMarker {
            try map.encodePostcardMap(to: encoder)
            return encoder.data
        }

        if let bytes = value as? [UInt8] {
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(bytes.count))
            encoder.data.append(contentsOf: bytes)
            return encoder.data
        }

        if let array = value as? PostcardArrayMarker {
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(array.postcardCount))
        }

        if let pcEnum = value as? any PostcardEnum {
            var sc = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try sc.encodeVarint(UInt64(pcEnum.postcardDiscriminant))
        }

        try value.encode(to: encoder)
        return encoder.data
    }
}

private protocol PostcardArrayMarker {
    var postcardCount: Int { get }
}
extension Array: PostcardArrayMarker {
    var postcardCount: Int { return count }
}

private protocol PostcardMapMarker {
    func encodePostcardMap(to encoder: _PostcardEncoder) throws
}
extension Dictionary: PostcardMapMarker {
    fileprivate func encodePostcardMap(to encoder: _PostcardEncoder) throws {
        // Postcard Map: varint(count) then (key, value) pairs
        var sc = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
        try sc.encodeVarint(UInt64(self.count))
        for (k, v) in self {
            if let encK = k as? Encodable, let encV = v as? Encodable {
                try encK.encode(to: encoder)
                try encV.encode(to: encoder)
            }
        }
    }
}

/// A custom Encoder that encodes Swift `Encodable` types into the Postcard binary format.
private class _PostcardEncoder: Encoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    // The accumulated bytes
    var data: [UInt8] = []

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key>
    where Key: CodingKey {
        let isEnum = (type is PostcardEnumKeys.Type)
        let container = _PostcardKeyedEncodingContainer<Key>(encoder: self, isEnum: isEnum)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _PostcardUnkeyedEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _PostcardSingleValueEncoder(encoder: self)
    }
}

private class _PostcardKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var codingPath: [CodingKey] { encoder.codingPath }
    let encoder: _PostcardEncoder
    let isEnum: Bool
    var wroteDiscriminant: Bool = false

    init(encoder: _PostcardEncoder, isEnum: Bool = false) {
        self.encoder = encoder
        self.isEnum = isEnum
    }

    private func writeDiscriminantIfNeeded(key: Key) throws {
        if isEnum && !wroteDiscriminant {
            guard let intValue = key.intValue else {
                throw ItoError.postcardEncodingError("Enum key '\(key.stringValue)' missing intValue for discriminant")
            }
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(intValue))
            wroteDiscriminant = true
        }
    }

    func encodeNil(forKey key: Key) throws {
        try writeDiscriminantIfNeeded(key: key)
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }

    func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        try writeDiscriminantIfNeeded(key: key)
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }

        if let map = value as? PostcardMapMarker {
            try map.encodePostcardMap(to: encoder)
            return
        }

        if let bytes = value as? [UInt8] {
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(bytes.count))
            encoder.data.append(contentsOf: bytes)
            return
        }

        if let array = value as? PostcardArrayMarker {
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(array.postcardCount))
        }

        try value.encode(to: encoder)
    }

    // Override encodeIfPresent to ensure `nil` is explicitly encoded as `0` in Postcard
    func encodeIfPresent<T>(_ value: T?, forKey key: Key) throws where T: Encodable {
        try writeDiscriminantIfNeeded(key: key)
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }

        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)

            if let map = value as? PostcardMapMarker {
                try map.encodePostcardMap(to: encoder)
                return
            }

            if let bytes = value as? [UInt8] {
                var single = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
                try single.encodeVarint(UInt64(bytes.count))
                encoder.data.append(contentsOf: bytes)
                return
            }

            if let array = value as? PostcardArrayMarker {
                var single = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
                try single.encodeVarint(UInt64(array.postcardCount))
            }

            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    func encodeIfPresent(_ value: Bool?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: String?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Double?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Float?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Int?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Int8?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Int16?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Int32?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: Int64?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: UInt?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws {
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        try? writeDiscriminantIfNeeded(key: key)
        encoder.codingPath.append(key)
        return encoder.container(keyedBy: keyType)
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        try? writeDiscriminantIfNeeded(key: key)
        encoder.codingPath.append(key)
        return encoder.unkeyedContainer()
    }

    func superEncoder() -> Encoder {
        return encoder
    }

    func superEncoder(forKey key: Key) -> Encoder {
        encoder.codingPath.append(key)
        return encoder
    }
}

private struct _PostcardUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    var codingPath: [CodingKey] { encoder.codingPath }
    let encoder: _PostcardEncoder
    var count: Int = 0

    // Sequences in Postcard are prefixed with their length as a varint.
    // For UnkeyedEncodingContainer, we actually don't know the length upfront
    // when it's requested. We rely on the Collection conformance of Array to encode
    // its length FIRST before delegating elements to us. Standard Library Array
    // does exactly this: `try container.encode(count)` then iterates elements.
    // However, Swift's default Array encoding doesn't know about Varints.
    // We will intercept Array encoding by requiring users to wrap arrays or
    // intercept it if possible. For standard Codable `[T]`, it iterates values.
    // We must ensure the count is encoded first.

    mutating func encodeNil() throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        var container = encoder.singleValueContainer()
        try container.encodeNil()
        count += 1
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }

        if let map = value as? PostcardMapMarker {
            try map.encodePostcardMap(to: encoder)
            count += 1
            return
        }

        if let bytes = value as? [UInt8] {
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(bytes.count))
            encoder.data.append(contentsOf: bytes)
            count += 1
            return
        }

        if let array = value as? PostcardArrayMarker {
            var container = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
            try container.encodeVarint(UInt64(array.postcardCount))
        }

        try value.encode(to: encoder)
        count += 1
    }

    mutating func encodeIfPresent<T>(_ value: T?) throws where T: Encodable {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            if let bytes = value as? [UInt8] {
                var single = encoder.singleValueContainer() as! _PostcardSingleValueEncoder
                try single.encodeVarint(UInt64(bytes.count))
                encoder.data.append(contentsOf: bytes)
            } else {
                try value.encode(to: encoder)
            }
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }

    mutating func encodeIfPresent(_ value: Bool?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: String?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Double?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Float?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Int?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Int8?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Int16?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Int32?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: Int64?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: UInt?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: UInt8?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: UInt16?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: UInt32?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func encodeIfPresent(_ value: UInt64?) throws {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        defer { encoder.codingPath.removeLast() }
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
        count += 1
    }
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type)
        -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        count += 1
        return encoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let key = AnyCodingKey(intValue: count)!
        encoder.codingPath.append(key)
        count += 1
        return encoder.unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        return encoder
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct _PostcardSingleValueEncoder: SingleValueEncodingContainer {
    var codingPath: [CodingKey] { encoder.codingPath }
    let encoder: _PostcardEncoder

    mutating func encodeNil() throws {
        // Postcard Option encoding: 0 for None, 1 for Some
        encoder.data.append(0)
    }

    mutating func encode(_ value: Bool) throws {
        encoder.data.append(value ? 1 : 0)
    }

    mutating func encode(_ value: String) throws {
        // Strings are preceded by their byte length (varint)
        let bytes = Array(value.utf8)
        try encodeVarint(UInt64(bytes.count))
        encoder.data.append(contentsOf: bytes)
    }

    mutating func encode(_ value: Double) throws {
        // f64: 8 bytes, little endian
        let bytes = withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
        encoder.data.append(contentsOf: bytes)
    }

    mutating func encode(_ value: Float) throws {
        // f32: 4 bytes, little endian
        let bytes = withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
        encoder.data.append(contentsOf: bytes)
    }

    mutating func encode(_ value: Int) throws {
        // Treat Swift Int as i64 mapped to zigzag varint
        try encodeZigZagVarint(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        let bytes = withUnsafeBytes(of: value.littleEndian, Array.init)
        encoder.data.append(contentsOf: bytes)
    }

    mutating func encode(_ value: Int16) throws {
        try encodeZigZagVarint(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        try encodeZigZagVarint(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        try encodeZigZagVarint(value)
    }

    mutating func encode(_ value: UInt) throws {
        // Treat Swift UInt as u64 varint
        try encodeVarint(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        encoder.data.append(value)
    }

    mutating func encode(_ value: UInt16) throws {
        try encodeVarint(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        try encodeVarint(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        try encodeVarint(value)
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        if let map = value as? PostcardMapMarker {
            try map.encodePostcardMap(to: encoder)
            return
        }

        if let array = value as? PostcardArrayMarker {
            try encodeVarint(UInt64(array.postcardCount))
        }
        try value.encode(to: encoder)
    }

    // MARK: - Postcard specific encoding helpers

    fileprivate mutating func encodeVarint(_ value: UInt64) throws {
        var v = value
        while v >= 0x80 {
            encoder.data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        encoder.data.append(UInt8(v & 0x7F))
    }

    private mutating func encodeZigZagVarint(_ value: Int64) throws {
        let zigZag = (UInt64(bitPattern: value) << 1) ^ UInt64(bitPattern: value >> 63)
        try encodeVarint(zigZag)
    }
}

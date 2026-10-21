import Foundation

/// A custom Decoder that decodes Postcard binary format into Swift `Decodable` types.
public struct ItoPostcardDecoder: Sendable {

    public init() {}

    /// Decodes a Postcard-formatted byte array into the specified type.
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The Postcard binary representation.
    /// - Returns: An instance of the requested type.
    /// - Throws: `ItoError.postcardDecodingError` if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from data: [UInt8]) throws -> T {
        let decoder = _PostcardDecoder(data: data)

        let isMap = (type is PostcardMapDecodable.Type)
        decoder.userInfo[mapFlagKey] = isMap

        if T.self is any PostcardEnum.Type {
            let singleDecoder = try decoder.singleValueContainer() as! _PostcardSingleValueDecoder
            let d = try singleDecoder.decodeVarint()
            decoder.userInfo[enumDiscriminantKey] = try narrow(d, to: UInt32.self)
        }

        let resolvedType = try T(from: decoder)

        // Ensure all bytes were consumed
        guard decoder.isAtEnd else {
            throw ItoError.postcardDecodingError(
                "Trailing unconsumed bytes present after decoding \(T.self). Consumed \(decoder.currentIndex) of \(data.count) bytes."
            )
        }

        return resolvedType
    }
}

// Internal protocol so Wrapper types can conform
protocol PostcardMapDecodable {}
extension Dictionary: PostcardMapDecodable {}
let mapFlagKey = CodingUserInfoKey(rawValue: "ito.postcard.isMap")!
let enumDiscriminantKey = CodingUserInfoKey(rawValue: "ito.postcard.enumDiscriminant")!

private class _PostcardDecoder: Decoder {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    let data: [UInt8]
    var currentIndex: Int = 0

    init(data: [UInt8]) {
        self.data = data
    }

    var isAtEnd: Bool {
        return currentIndex >= data.count
    }

    func consume(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= data.count - currentIndex else {
            throw ItoError.postcardDecodingError(
                "Unexpected end of data while attempting to read \(count) bytes.")
        }
        let slice = data[currentIndex..<(currentIndex + count)]
        currentIndex += count
        return slice
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key>
    where Key: CodingKey {
        if String(describing: type).contains("DictionaryCodingKey") {
            let context = DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Force fallback to unkeyed container for Dictionary")
            throw DecodingError.typeMismatch(type, context)
        }
        let isEnum = (type is PostcardEnumKeys.Type)
        let container = try _PostcardKeyedDecodingContainer<Key>(decoder: self, isEnum: isEnum)
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        return try _PostcardUnkeyedDecodingContainer(decoder: self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _PostcardSingleValueDecoder(decoder: self)
    }

    func withMapFlag<T, R>(_ type: T.Type, block: () throws -> R) rethrows -> R {
        let isMap = (type is PostcardMapDecodable.Type)
        let previous = userInfo[mapFlagKey]
        userInfo[mapFlagKey] = isMap
        defer { userInfo[mapFlagKey] = previous }
        return try block()
    }
}

private struct _PostcardKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    var codingPath: [CodingKey] { decoder.codingPath }
    let decoder: _PostcardDecoder
    let isEnum: Bool
    let discriminant: UInt32?
    var allKeys: [Key] = []

    init(decoder: _PostcardDecoder, isEnum: Bool = false) throws {
        self.decoder = decoder
        self.isEnum = isEnum

        if let d = decoder.userInfo[enumDiscriminantKey] as? UInt32 {
            self.discriminant = d
            // Clear it so nested enums don't reuse it
            decoder.userInfo[enumDiscriminantKey] = nil
        } else if isEnum {
            let singleDecoder = try decoder.singleValueContainer() as! _PostcardSingleValueDecoder
            let d = try singleDecoder.decodeVarint()
            self.discriminant = try narrow(d, to: UInt32.self)
        } else {
            self.discriminant = nil
        }

        if let discriminant = self.discriminant {
            let key = Key(intValue: Int(discriminant))
            if let key = key {
                self.allKeys = [key]
            }
        }
    }

    func contains(_ key: Key) -> Bool {
        if let discriminant = discriminant {
            return key.intValue == Int(discriminant)
        }
        return true
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        if !decoder.isAtEnd && decoder.data[decoder.currentIndex] == 0 {
            decoder.currentIndex += 1
            return true
        }
        if !decoder.isAtEnd && decoder.data[decoder.currentIndex] == 1 {
            decoder.currentIndex += 1
        }
        return false
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        return try decoder.withMapFlag(type) {
            try T(from: decoder)
        }
    }

    func decodeIfPresent<T>(_ type: T.Type, forKey key: Key) throws -> T? where T: Decodable {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try decoder.withMapFlag(type) {
            try T(from: decoder)
        }
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Bool(from: decoder)
    }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try String(from: decoder)
    }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Double(from: decoder)
    }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Float(from: decoder)
    }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Int(from: decoder)
    }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Int8(from: decoder)
    }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Int16(from: decoder)
    }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Int32(from: decoder)
    }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try Int64(from: decoder)
    }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try UInt(from: decoder)
    }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try UInt8(from: decoder)
    }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try UInt16(from: decoder)
    }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try UInt32(from: decoder)
    }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let isNil = try decodeNil(forKey: key)
        if isNil {
            return nil
        }
        return try UInt64(from: decoder)
    }
    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        decoder.codingPath.append(key)
        return try decoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        decoder.codingPath.append(key)
        return try decoder.unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        return decoder
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        decoder.codingPath.append(key)
        return decoder
    }
}

private struct _PostcardUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    var codingPath: [CodingKey] { decoder.codingPath }
    let decoder: _PostcardDecoder
    var count: Int?
    var currentIndex: Int = 0

    init(decoder: _PostcardDecoder) throws {
        self.decoder = decoder
        // In Postcard, sequences always start with a varint length, read here so `isAtEnd` works.
        let singleDecoder = try decoder.singleValueContainer() as! _PostcardSingleValueDecoder
        let length = try narrow(singleDecoder.decodeVarint(), to: Int.self)
        if let isMap = decoder.userInfo[mapFlagKey] as? Bool, isMap {
            // For maps the length counts entries, but the container iterates keys and values.
            let (items, overflow) = length.multipliedReportingOverflow(by: 2)
            guard !overflow else {
                throw ItoError.postcardDecodingError("Map length \(length) is too large.")
            }
            self.count = items
        } else {
            self.count = length
        }
    }

    var isAtEnd: Bool {
        return currentIndex >= (count ?? 0)
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw ItoError.postcardDecodingError("Unkeyed container is at end.") }
        let key = AnyCodingKey(intValue: currentIndex)!
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }
        let isNil = try _PostcardSingleValueDecoder(decoder: decoder).decodeNil()
        if !isNil {
            // We didn't consume it if it was not nil (in some implementations)
            // but our single value decoder DOES consume the `1` byte.
        }
        currentIndex += 1
        return isNil
    }

    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        guard !isAtEnd else { throw ItoError.postcardDecodingError("Unkeyed container is at end.") }
        let key = AnyCodingKey(intValue: currentIndex)!
        decoder.codingPath.append(key)
        defer { decoder.codingPath.removeLast() }

        let value = try decoder.withMapFlag(type) {
            try T(from: decoder)
        }
        currentIndex += 1
        return value
    }

    mutating func decodeIfPresent(_ type: Bool.Type) throws -> Bool? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Bool(from: decoder)
    }
    mutating func decodeIfPresent(_ type: String.Type) throws -> String? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try String(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Double.Type) throws -> Double? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Double(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Float.Type) throws -> Float? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Float(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Int.Type) throws -> Int? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Int(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Int8.Type) throws -> Int8? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Int8(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Int16.Type) throws -> Int16? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Int16(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Int32.Type) throws -> Int32? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Int32(from: decoder)
    }
    mutating func decodeIfPresent(_ type: Int64.Type) throws -> Int64? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try Int64(from: decoder)
    }
    mutating func decodeIfPresent(_ type: UInt.Type) throws -> UInt? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try UInt(from: decoder)
    }
    mutating func decodeIfPresent(_ type: UInt8.Type) throws -> UInt8? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try UInt8(from: decoder)
    }
    mutating func decodeIfPresent(_ type: UInt16.Type) throws -> UInt16? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try UInt16(from: decoder)
    }
    mutating func decodeIfPresent(_ type: UInt32.Type) throws -> UInt32? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try UInt32(from: decoder)
    }
    mutating func decodeIfPresent(_ type: UInt64.Type) throws -> UInt64? {
        let isNil = try decodeNil()
        if isNil {
            return nil
        }
        return try UInt64(from: decoder)
    }
    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        guard !isAtEnd else { throw ItoError.postcardDecodingError("Unkeyed container is at end.") }
        let key = AnyCodingKey(intValue: currentIndex)!
        decoder.codingPath.append(key)
        currentIndex += 1
        return try decoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard !isAtEnd else { throw ItoError.postcardDecodingError("Unkeyed container is at end.") }
        let key = AnyCodingKey(intValue: currentIndex)!
        decoder.codingPath.append(key)
        currentIndex += 1
        return try decoder.unkeyedContainer()
    }
    mutating func superDecoder() throws -> Decoder {
        return decoder
    }
}

private struct _PostcardSingleValueDecoder: SingleValueDecodingContainer {
    var codingPath: [CodingKey] { decoder.codingPath }
    let decoder: _PostcardDecoder

    func decodeNil() -> Bool {
        // We peek to see if the next byte is 0 (None)
        if !decoder.isAtEnd && decoder.data[decoder.currentIndex] == 0 {
            decoder.currentIndex += 1
            return true
        }
        // If it's 1 (Some), we consume it and return false meaning "not nil"
        if !decoder.isAtEnd && decoder.data[decoder.currentIndex] == 1 {
            decoder.currentIndex += 1
        }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        let byte = try decoder.consume(1).first!
        switch byte {
        case 0: return false
        case 1: return true
        default: throw ItoError.postcardDecodingError("Invalid boolean byte: \(byte)")
        }
    }

    func decode(_ type: String.Type) throws -> String {
        let length = try decodeVarint()
        guard length <= Int.max else {
            throw ItoError.postcardDecodingError("String length exceeds maximum supported size.")
        }

        let slice = try decoder.consume(Int(length))
        guard let string = String(bytes: slice, encoding: .utf8) else {
            throw ItoError.postcardDecodingError("Failed to decode UTF-8 string.")
        }
        return string
    }

    func decode(_ type: Double.Type) throws -> Double {
        let bytes = try decoder.consume(8)
        let bitPattern = Array(bytes).withUnsafeBytes { $0.load(as: UInt64.self) }
        return Double(bitPattern: UInt64(littleEndian: bitPattern))
    }

    func decode(_ type: Float.Type) throws -> Float {
        let bytes = try decoder.consume(4)
        let bitPattern = Array(bytes).withUnsafeBytes { $0.load(as: UInt32.self) }
        return Float(bitPattern: UInt32(littleEndian: bitPattern))
    }

    func decode(_ type: Int.Type) throws -> Int {
        // Decode i64 zig-zag mapped to Int
        let zigZag = try decodeVarint()
        return try narrow(decodeZigZag(zigZag), to: Int.self)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        let byte = try decoder.consume(1).first!
        return Int8(bitPattern: byte)  // Not zig-zag encoded per Postcard spec.
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        let zigZag = try decodeVarint()
        return try narrow(decodeZigZag(zigZag), to: Int16.self)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        let zigZag = try decodeVarint()
        return try narrow(decodeZigZag(zigZag), to: Int32.self)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        let zigZag = try decodeVarint()
        return decodeZigZag(zigZag)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        return try narrow(decodeVarint(), to: UInt.self)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        return try decoder.consume(1).first!
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        return try narrow(decodeVarint(), to: UInt16.self)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        return try narrow(decodeVarint(), to: UInt32.self)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        return try decodeVarint()
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        return try decoder.withMapFlag(type) {
            try T(from: decoder)
        }
    }

    // MARK: - Postcard specific decoding helpers

    fileprivate func decodeVarint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var byte: UInt8 = 0

        repeat {
            byte = try decoder.consume(1).first!
            value |= UInt64(byte & 0x7F) << shift
            shift += 7

            // Postcard uses at most 10 bytes for varints
            if shift > 70 {
                throw ItoError.postcardDecodingError("Varint exceeds maximum 64-bit size.")
            }
        } while (byte & 0x80) != 0

        return value
    }

    private func decodeZigZag(_ value: UInt64) -> Int64 {
        return Int64(bitPattern: (value >> 1) ^ (~(value & 1) &+ 1))
    }
}

/// Converts a decoded integer to a narrower type, throwing when the plugin sent a value that
/// doesn't fit instead of trapping and taking the app down with it.
private func narrow<Source: BinaryInteger, Target: FixedWidthInteger>(
    _ value: Source,
    to _: Target.Type
) throws -> Target {
    guard let narrowed = Target(exactly: value) else {
        throw ItoError.postcardDecodingError("Value \(value) does not fit in \(Target.self).")
    }
    return narrowed
}

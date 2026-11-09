import OSLog
import Foundation
import Testing

@testable import ito_runner

@Suite("Detailed Postcard Serialization Tests")
struct PostcardDetailedTests {

    let encoder = ItoPostcardEncoder(abiVersion: 2)
    let decoder = ItoPostcardDecoder(abiVersion: 2)

    // MARK: - Integer Tests (Varint & ZigZag)

    @Test("Integer Encoding/Decoding")
    func testIntegers() throws {
        struct IntContainer: Codable, Equatable {
            let i8: Int8
            let i16: Int16
            let i32: Int32
            let i64: Int64
            let u8: UInt8
            let u16: UInt16
            let u32: UInt32
            let u64: UInt64
        }

        let values: [IntContainer] = [
            IntContainer(i8: 0, i16: 0, i32: 0, i64: 0, u8: 0, u16: 0, u32: 0, u64: 0),
            IntContainer(i8: 1, i16: 1, i32: 1, i64: 1, u8: 1, u16: 1, u32: 1, u64: 1),
            IntContainer(i8: -1, i16: -1, i32: -1, i64: -1, u8: 0, u16: 0, u32: 0, u64: 0),
            IntContainer(
                i8: .max, i16: .max, i32: .max, i64: .max, u8: .max, u16: .max, u32: .max, u64: .max
            ),
            IntContainer(i8: .min, i16: .min, i32: .min, i64: .min, u8: 0, u16: 0, u32: 0, u64: 0)
        ]

        for val in values {
            let data = try encoder.encode(val)
            let decoded = try decoder.decode(IntContainer.self, from: data)
            #expect(decoded == val)
        }
    }

    @Test("ZigZag Specific Cases")
    func testZigZag() throws {
        // We verify specific known Postcard/ZigZag byte sequences if possible,
        // or just rely on the roundtrip above.
        // ZigZag: 0 -> 0, -1 -> 1, 1 -> 2, -2 -> 3

        struct Wrapper: Codable, Equatable {
            let v: Int32
        }

        // 0 -> 0x00
        #expect(try encoder.encode(Wrapper(v: 0)) == [0])
        // -1 -> 0x01
        #expect(try encoder.encode(Wrapper(v: -1)) == [1])
        // 1 -> 0x02
        #expect(try encoder.encode(Wrapper(v: 1)) == [2])
        // -2 -> 0x03
        #expect(try encoder.encode(Wrapper(v: -2)) == [3])

        // 64 -> 128 (0x80) -> varint -> [0x80, 0x01]
        // 1000 0000 -> drop MSB -> 0000000. Next byte 1 -> 0000001.
        // value = 0 | (1 << 7) = 128. Correct.
        #expect(try encoder.encode(Wrapper(v: 64)) == [0x80, 0x01])
    }

    // MARK: - Floating Point Tests

    @Test("Floating Point Encoding/Decoding")
    func testFloats() throws {
        struct FloatContainer: Codable, Equatable {
            let f: Float
            let d: Double
        }

        let values = [
            FloatContainer(f: 0.0, d: 0.0),
            FloatContainer(f: 1.5, d: 1.5),
            FloatContainer(f: -1.5, d: -1.5),
            FloatContainer(f: 3.14159, d: 3.14159265359)
        ]

        for val in values {
            let data = try encoder.encode(val)
            let decoded = try decoder.decode(FloatContainer.self, from: data)
            #expect(decoded.f == val.f)
            #expect(decoded.d == val.d)
        }
    }

    // MARK: - String Tests

    @Test("String Encoding/Decoding")
    func testStrings() throws {
        struct StringContainer: Codable, Equatable {
            let s: String
        }

        let values = [
            "",
            "hello",
            "Hello World",
            "🚀🔥Code",
            "Multi\nLine"
        ]

        for s in values {
            let val = StringContainer(s: s)
            let data = try encoder.encode(val)
            let decoded = try decoder.decode(StringContainer.self, from: data)
            #expect(decoded == val)
        }
    }

    // MARK: - Array Tests

    @Test("Array Encoding/Decoding")
    func testArrays() throws {
        struct ArrayContainer: Codable, Equatable {
            let list: [Int32]
            let strings: [String]
        }

        let val = ArrayContainer(
            list: [1, 2, 3, 100, -5],
            strings: ["A", "B", "C"]
        )

        let data = try encoder.encode(val)
        let decoded = try decoder.decode(ArrayContainer.self, from: data)
        #expect(decoded == val)

        // Empty arrays
        let emptyVal = ArrayContainer(list: [], strings: [])
        let emptyData = try encoder.encode(emptyVal)
        let emptyDecoded = try decoder.decode(ArrayContainer.self, from: emptyData)
        #expect(emptyDecoded == emptyVal)
    }

    // MARK: - Optional Tests

    @Test("Optional Encoding/Decoding")
    func testOptionals() throws {
        struct OptionalContainer: Codable, Equatable {
            let i: Int32?
            let s: String?
        }

        let bothNil = OptionalContainer(i: nil, s: nil)
        let bothSome = OptionalContainer(i: 42, s: "Exists")
        let mixed1 = OptionalContainer(i: 42, s: nil)
        let mixed2 = OptionalContainer(i: nil, s: "Exists")

        // Test Both Nil
        // i: 0 (None), s: 0 (None) -> [0, 0]
        let dataNil = try encoder.encode(bothNil)
        #expect(dataNil == [0, 0])
        #expect(try decoder.decode(OptionalContainer.self, from: dataNil) == bothNil)

        // Test Both Some
        // i: 1 (Some), 42 (zigzag 84 -> 0x54), s: 1 (Some), 6 (len), "Exists"
        let dataSome = try encoder.encode(bothSome)
        let decodedSome = try decoder.decode(OptionalContainer.self, from: dataSome)
        #expect(decodedSome == bothSome)

        #expect(
            try decoder.decode(OptionalContainer.self, from: try encoder.encode(mixed1)) == mixed1)
        #expect(
            try decoder.decode(OptionalContainer.self, from: try encoder.encode(mixed2)) == mixed2)
    }

    // MARK: - Complex/Nested Tests

    @Test("Complex Nested Structures")
    func testComplexNested() throws {
        struct Child: Codable, Equatable {
            let id: Int
            let tags: [String]
        }
        struct Parent: Codable, Equatable {
            let name: String
            let children: [Child]
            @PostcardMapCoded var metadata: [String: String]  // Dictionary test
        }

        // Note: Postcard Map order is not guaranteed by Swift Dictionary iteration,
        // so binary equality check might fail if we checked `data` directly.
        // We rely on roundtrip equality.

        let parent = Parent(
            name: "Root",
            children: [
                Child(id: 1, tags: ["a", "b"]),
                Child(id: 2, tags: [])
            ],
            metadata: ["key1": "value1", "key2": "value2"]
        )

        let data = try encoder.encode(parent)
        RunnerLogger.core.debug("Encoded length: \(data.count)")
        RunnerLogger.core.debug("Encoded data: \(data)")

        do {
            let decoded = try decoder.decode(Parent.self, from: data)
            #expect(decoded.name == parent.name)
            #expect(decoded.children == parent.children)
            #expect(decoded.metadata == parent.metadata)
        } catch {
            RunnerLogger.core.error("Caught error: \(error)")
            throw error
        }
    }
}

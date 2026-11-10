import OSLog
import Testing
import Foundation
@testable import ito_runner

@Suite("Postcard Encoder/Decoder Tests")
struct PostcardCodecTests {

    struct SimpleStruct: Codable, Equatable {
        let id: UInt32
        let name: String
        let isActive: Bool
    }

    @Test("Encode and Decode Simple Struct")
    func testSimpleStructRoundtrip() throws {
        let encoder = ItoPostcardEncoder(abiVersion: 3)
        let decoder = ItoPostcardDecoder(abiVersion: 3)

        let original = SimpleStruct(id: 42, name: "Test Wasm Plugin", isActive: true)

        let encoded = try encoder.encode(original)

        // Postcard encoding of varint 42 is [42]
        // "Test Wasm Plugin" is 16 bytes: [16, 84, 101, 115, 116, 32, 87, 97, 115, 109, 32, 80, 108, 117, 103, 105, 110]
        // isActive true is [1]
        // Expect: [42, 16, 84, 101, 115, 116, 32, 87, 97, 115, 109, 32, 80, 108, 117, 103, 105, 110, 1] => 19 bytes

        #expect(encoded.count == 19)
        #expect(encoded.first == 42)
        #expect(encoded.last == 1)

        let decoded = try decoder.decode(SimpleStruct.self, from: encoded)

        #expect(decoded == original)
    }

    struct ComplexStruct: Codable, Equatable {
        let values: [Int32]
        let optionalString: String?
    }

    @Test("Encode and Decode Arrays and Optionals")
    func testComplexStructRoundtrip() throws {
        let encoder = ItoPostcardEncoder(abiVersion: 3)
        let decoder = ItoPostcardDecoder(abiVersion: 3)

        let original = ComplexStruct(values: [-1, 0, 1, 100], optionalString: nil)

        let encoded = try encoder.encode(original); RunnerLogger.core.debug("ENCODED BYTES: \(encoded)")
        let decoded = try decoder.decode(ComplexStruct.self, from: encoded)

        #expect(decoded == original)
    }
}

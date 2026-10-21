import Foundation
import Testing
@testable import ito_runner

@Suite("Settings schema decoding")
struct SettingsSchemaDecodingTests {
    /// Bytes produced by ito-rs `postcard::to_allocvec` for a schema with a Text setting
    /// (variant 1) and a Secret setting (variant 3).
    private static let itoRsSchema = "0201067365727665720a5365727665722055524c000003076170695f6b657907415049206b6579011146726f6d20796f7572206163636f756e74"

    @Test func decodesTheSecretSettingProducedByTheRustSDK() throws {
        let schema = try ItoPostcardDecoder().decode(SettingsSchema.self, from: Self.bytes(Self.itoRsSchema))

        #expect(schema.settings.count == 2)
        guard case .text(let textID, let textName, let textSummary, let textDefault) = schema.settings[0] else {
            Issue.record("Expected a text setting, got \(schema.settings[0])")
            return
        }
        #expect(textID == "server")
        #expect(textName == "Server URL")
        #expect(textSummary == nil)
        #expect(textDefault.isEmpty)

        guard case .secret(let id, let name, let summary) = schema.settings[1] else {
            Issue.record("Expected a secret setting, got \(schema.settings[1])")
            return
        }
        #expect(id == "api_key")
        #expect(name == "API key")
        #expect(summary == "From your account")
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }
}

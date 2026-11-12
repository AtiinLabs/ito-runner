import CryptoKit
import Foundation
import Testing
@testable import ito_runner

struct EditionsFixture: Decodable {
    struct Wire: Decodable {
        let name: String
        let hex: String
        let repeat_hex: String?
        let repeat_count: Int?
        let suffix_hex: String?
        let canonical_hex: String?
        let limit: UInt32?
        let expect: String
        var bytes: [UInt8] {
            var bytes = decodeHex(hex)
            if let unit = repeat_hex, let count = repeat_count {
                for _ in 0..<count { bytes += decodeHex(unit) }
            }
            return bytes + decodeHex(suffix_hex ?? "")
        }
    }
    struct Limits: Decodable { let max_limit: Int; let max_cursor_bytes: Int; let max_response_bytes: Int }
    struct RunLimits: Decodable { let max_rows: Int; let max_pages: Int; let max_cumulative_bytes: Int }
    let contract: String
    let version: Int
    let codes: [String]
    let limits: Limits
    let run_limits: RunLimits
    let requests: [Wire]
    let pages: [Wire]
    static let url = Bundle.module.url(forResource: "chapter-editions-v1", withExtension: "json", subdirectory: "Fixtures")!
    static let shared = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
}

struct EditionsTraversalFixture: Decodable {
    struct Case: Decodable {
        struct Expected: Decodable {
            let outcome: String
            let termination: String?
            let scope: String?
            let completeness: String?
            let keys: [String]?
            let kinds: [String]?
            let calls: Int
        }
        let name: String
        let limit: Int
        let pages: [String]
        let expect: Expected
    }
    let cases: [Case]
    static let shared = try! JSONDecoder().decode(Self.self, from: Data(contentsOf:
        Bundle.module.url(forResource: "chapter-editions-traversal-v1", withExtension: "json", subdirectory: "Fixtures")!))
}

func editionsErrorCode(_ error: any Error) -> String? {
    switch error {
    case let violation as ChapterEditionsViolation: return violation.rule.rawValue
    case let violation as CatalogContractViolation: return violation.rule.rawValue
    case ItoError.chapterEditionsViolation(_, let violation): return violation.rule.rawValue
    case ItoError.catalogContractViolation(_, let violation): return violation.rule.rawValue
    default: return nil
    }
}

@Suite("Chapter editions SDK wire fixtures")
struct ChapterEditionsFixtureTests {
    @Test func sdkFixtureIsPinnedByteForByte() throws {
        let digest = SHA256.hash(data: try Data(contentsOf: EditionsFixture.url)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "efbc2d1dc1328b9a42bbff50a671177595de1212042752325e7411a220a31357")
        let fixture = EditionsFixture.shared
        #expect(fixture.contract == "ito-chapter-editions" && fixture.version == 1)
        #expect(fixture.codes == ChapterEditionsViolation.Rule.allCases.filter { !$0.isHostOnly }.map(\.rawValue))
        #expect(fixture.limits.max_limit == ChapterEditionsLimits.maxLimit)
        #expect(fixture.limits.max_cursor_bytes == ChapterEditionsLimits.maxCursorBytes)
        #expect(fixture.limits.max_response_bytes == CatalogLimits.responseBytes)
        #expect(fixture.run_limits.max_rows == ChapterEditionsLimits.maxRows)
        #expect(fixture.run_limits.max_pages == ChapterEditionsLimits.maxPages)
        #expect(fixture.run_limits.max_cumulative_bytes == ChapterEditionsLimits.maxCumulativeBytes)
    }

    @Test func everyRequestAndPageHasTheSDKVerdictAndCanonicalEncoding() throws {
        for (request, wires) in [(true, EditionsFixture.shared.requests), (false, EditionsFixture.shared.pages)] {
            for wire in wires {
                var verdict = "ok"
                do {
                    let encoded: [UInt8]
                    if request {
                        let value = try editionsDecoder.decode(ChapterEditionsRequest.self, from: wire.bytes)
                        try ChapterEditionsValidation.request(value)
                        encoded = try editionsEncoder.encode(value)
                    } else {
                        let value = try editionsDecoder.decode(ChapterEditionsPage.self, from: wire.bytes)
                        try ChapterEditionsValidation.page(value, limit: wire.limit!)
                        encoded = try editionsEncoder.encode(value)
                    }
                    #expect(encoded == (wire.canonical_hex.map(decodeHex) ?? wire.bytes), Comment(rawValue: wire.name))
                } catch {
                    verdict = editionsErrorCode(error).map { "violation:\($0)" } ?? "decode_error"
                }
                #expect(verdict == wire.expect, Comment(rawValue: wire.name))
            }
        }
    }

    @Test func everyTraversalFixtureRunsThroughWasmDispatch() async throws {
        for test in EditionsTraversalFixture.shared.cases {
            let steps = test.pages.map { EditionsTestStep(bytes: decodeHex($0)) }
            let runner = ItoRunner()
            try await runner.loadPlugin(fromBytes: editionsPlugin(steps))
            do {
                let result = try #require(try await runner.getChapterEditions(editionsEntry, limit: test.limit, context: .test))
                #expect(test.expect.outcome == "ok", Comment(rawValue: test.name))
                #expect(result.editions.map(\.key) == test.expect.keys)
                #expect(result.editions.map { $0.kind!.rawValue } == test.expect.kinds)
                #expect(result.termination == .exhausted)
                #expect(String(describing: result.scope) == test.expect.scope)
                #expect(String(describing: result.completeness) == test.expect.completeness)
                #expect(result.pageCount == test.expect.calls)
                #expect(result.encodedBytes == test.pages.reduce(0) { $0 + decodeHex($1).count })
            } catch {
                #expect(editionsErrorCode(error).map { "violation:\($0)" } == test.expect.outcome, Comment(rawValue: test.name))
            }
            #expect(try await editionsCalls(runner) == test.expect.calls, Comment(rawValue: test.name))
            let requests = try await editionsRequests(runner)
            #expect(requests.first?.cursor == nil)
            for index in requests.indices {
                #expect(requests[index].entry.key == editionsEntry.key)
                #expect(requests[index].limit == UInt32(test.limit))
                if index > 0 {
                    let previous = try editionsDecoder.decode(ChapterEditionsPage.self, from: decodeHex(test.pages[index - 1]))
                    #expect(requests[index].cursor?.utf8.elementsEqual(previous.nextCursor!.utf8) == true)
                }
            }
        }
    }

    @Test func mixedPagePreservesTextAndImages() throws {
        let wire = EditionsFixture.shared.pages.first { $0.name == "page.mixed_nonterminal" }!
        let page = try editionsDecoder.decode(ChapterEditionsPage.self, from: wire.bytes)
        #expect(page.editions.map(\.kind) == [.text, .images])
    }
}

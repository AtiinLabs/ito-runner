import Testing

@testable import ito_runner

/// A module of `() -> ()` functions, each declaring its locals as a single run of i32s, so a large
/// count costs a few bytes in the file but its full size when parsing expands it.
private func module(localsPerFunction: [UInt32]) -> [UInt8] {
    func leb(_ value: UInt32) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }
    func section(_ id: UInt8, _ contents: [UInt8]) -> [UInt8] {
        [id] + leb(UInt32(contents.count)) + contents
    }
    let count = leb(UInt32(localsPerFunction.count))
    let types = section(1, [0x01, 0x60, 0x00, 0x00])
    let functions = section(3, count + [UInt8](repeating: 0x00, count: localsPerFunction.count))
    let bodies = localsPerFunction.flatMap { locals -> [UInt8] in
        let body = [0x01] + leb(locals) + [0x7F, 0x0B]
        return leb(UInt32(body.count)) + body
    }
    return [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00] + types + functions + section(10, count + bodies)
}

@Suite("Module parsing limits")
struct ModuleParsingLimitsTests {
    @Test func aFunctionMayDeclareUpToTheLimitInclusive() throws {
        #expect(throws: Never.self) { try ItoRunner.inspectBinary(module(localsPerFunction: [10_000])) }
        #expect(throws: ItoError.self) { try ItoRunner.inspectBinary(module(localsPerFunction: [10_001])) }
    }

    @Test func allFunctionsTogetherMayDeclareUpToTheTotalInclusive() throws {
        let atTotal = [UInt32](repeating: 10_000, count: 25)

        #expect(throws: Never.self) { try ItoRunner.inspectBinary(module(localsPerFunction: atTotal)) }
        #expect(throws: ItoError.self) { try ItoRunner.inspectBinary(module(localsPerFunction: atTotal + [1])) }
    }

    @Test func loadingRefusesAModuleOverTheLimits() async throws {
        let runner = ItoRunner()

        await #expect(throws: ItoError.self) {
            try await runner.loadPlugin(fromBytes: module(localsPerFunction: [1_000_000]))
        }
    }
}

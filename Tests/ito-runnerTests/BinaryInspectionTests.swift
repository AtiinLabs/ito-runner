import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

/// Records what a plugin prints, so a test can tell whether any plugin code ran.
private final class RecordingStdModule: StdModule, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func print(message: String) { lock.withLock { recorded.append(message) } }
    var messages: [String] { lock.withLock { recorded } }
}

private func wasm(_ body: String) throws -> [UInt8] {
    try wat2wasm("(module \(body))")
}

private func abiExport(_ value: Int) -> String {
    #"(func (export "ito_abi_version") (result i32) i32.const \#(value))"#
}

private func kindsExport(_ mask: Int) -> String {
    #"(func (export "ito_supported_kinds") (result i32) i32.const \#(mask))"#
}

private func errorExport(_ version: Int) -> String {
    #"(func (export "ito_error_version") (result i32) i32.const \#(version))"#
}

@Suite("Static binary inspection")
struct BinaryInspectionTests {

    // MARK: ABI

    @Test func aModuleWithoutTheABIExportIsABI1() throws {
        let binary = try ItoRunner.inspectBinary(wasm(#"(func (export "get_home") (result i64) i64.const 0)"#))

        #expect(binary == PluginBinaryInterface(abiVersion: 1, imports: [], kinds: nil, errorProtocolVersion: 1))
    }

    @Test(arguments: [0, 1, 2, 3, 7])
    func theABIIsTheConstantTheExportReturns(version: Int) throws {
        let binary = try ItoRunner.inspectBinary(wasm(abiExport(version)))

        #expect(binary.abiVersion == version)
        #expect(!binary.hasStartSection)
    }

    @Test func aNegativeConstantIsAHugeVersionNotAnOldOne() throws {
        let binary = try ItoRunner.inspectBinary(wasm(abiExport(-1)))

        #expect(binary.abiVersion == Int(UInt32.max))
        #expect(ItoRunner.compatibility(of: binary) == .pluginTooNew(abi: Int(UInt32.max)))
    }

    @Test func theABIExportIsFoundAfterImportedFunctionsAndOtherImports() throws {
        let binary = try ItoRunner.inspectBinary(wasm("""
            (import "ito:core/std" "print" (func (param i32 i32)))
            (import "env" "table" (table 1 funcref))
            (import "ito:core/env" "get_languages" (func (result i64)))
            (func (export "other") (result i32) i32.const 9)
            \(abiExport(2))
            \(kindsExport(1))
            (func (export "ito_error_version") (result i32) i32.const 5)
            """))

        #expect(binary.abiVersion == 2)
        #expect(binary.kinds == [.manga])
        #expect(binary.errorProtocolVersion == 5)
    }

    @Test func aBodyThatIsNotASingleConstantIsRefused() throws {
        let bodies = [
            "i32.const 1 i32.const 1 i32.add",
            "i32.const 2 drop i32.const 2",
            "i32.const 2 nop",
            "(local i32) local.get 0",
            "i32.const 2 return",
            "i32.const 2 i32.const 3 i32.const 1 select",
            "call $helper",
            "i64.const 2 i32.wrap_i64"
        ]
        for body in bodies {
            let module = try wasm("""
                (func $helper (result i32) i32.const 2)
                (func (export "ito_abi_version") (result i32) \(body))
                """)
            #expect(throws: ItoError.self, Comment(rawValue: body)) {
                try ItoRunner.inspectBinary(module)
            }
        }
    }

    @Test func aNonConstantKindsExportLeavesTheMaskUnreadWithoutRefusingTheFile() throws {
        let module = try wasm("""
            \(abiExport(3))
            \(errorExport(2))
            (func (export "ito_supported_kinds") (result i32) i32.const 1 i32.const 1 i32.or)
            """)

        let binary = try ItoRunner.inspectBinary(module)

        #expect(binary.abiVersion == 3)
        #expect(binary.kindsMask == nil)
        #expect(ItoRunner.compatibility(of: binary) == .invalid)
    }

    @Test func anABIExportThatIsImportedNotDefinedIsRefused() throws {
        let module = try wasm("""
            (import "env" "abi" (func $abi (result i32)))
            (export "ito_abi_version" (func $abi))
            """)

        #expect(throws: ItoError.self) { try ItoRunner.inspectBinary(module) }
    }

    @Test func aMemoryNamedLikeTheABIExportIsNotTheExport() throws {
        let binary = try ItoRunner.inspectBinary(wasm(#"(memory (export "ito_abi_version") 1)"#))

        #expect(binary.abiVersion == 1)
    }

    @Test(arguments: [
        [UInt8](), [0x00, 0x61, 0x73], Array("not a wasm module".utf8),
        [0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00]
    ])
    func bytesThatAreNotAModuleAreRefused(bytes: [UInt8]) {
        #expect(throws: ItoError.self) { try ItoRunner.inspectBinary(bytes) }
    }

    @Test func aTruncatedModuleIsRefused() throws {
        let module = try wasm("(memory 1)\n\(abiExport(2))")

        #expect(throws: ItoError.self) { try ItoRunner.inspectBinary(Array(module.dropLast(3))) }
    }

    // MARK: Kinds

    @Test func kindsComeFromTheMaskInKindOrder() throws {
        let expected: [Int: [MediaKind]] = [
            1: [.manga], 2: [.anime], 4: [.novel], 5: [.manga, .novel], 7: [.manga, .anime, .novel]
        ]
        for (mask, kinds) in expected {
            let binary = try ItoRunner.inspectBinary(wasm(abiExport(2) + kindsExport(mask)))
            #expect(binary.kinds == kinds, Comment(rawValue: "mask \(mask)"))
        }
    }

    @Test func theMaskIsReadFromABI2OnWhateverTheRunnersRangeAndNotBefore() throws {
        let abi1 = try ItoRunner.inspectBinary(wasm(abiExport(1) + kindsExport(4)))
        let unversioned = try ItoRunner.inspectBinary(wasm(kindsExport(4)))
        let abi2 = try ItoRunner.inspectBinary(wasm(abiExport(2) + kindsExport(4)))
        let abi3 = try ItoRunner.inspectBinary(wasm(abiExport(3) + kindsExport(4)))
        let withoutExport = try ItoRunner.inspectBinary(wasm(abiExport(2)))

        #expect(abi1.kindsMask == nil && abi1.kinds == nil)
        #expect(unversioned.kindsMask == nil && unversioned.kinds == nil)
        #expect(abi2.kindsMask == 4 && abi2.kinds == [.novel])
        #expect(abi3.kindsMask == 4 && abi3.kinds == [.novel])
        #expect(withoutExport.kindsMask == nil && withoutExport.kinds == nil)
    }

    @Test(arguments: [0, 8, 9, 255])
    func aMaskNamingNoKindOrAnUnknownOneIsKeptRawAndMakesAnInRangeFileInvalid(mask: Int) throws {
        let abi2 = try ItoRunner.inspectBinary(wasm(abiExport(2) + kindsExport(mask) + errorExport(2)))
        let abi3 = try ItoRunner.inspectBinary(wasm(abiExport(3) + kindsExport(mask) + errorExport(2)))

        #expect(abi2.kindsMask == UInt32(mask))
        #expect(abi2.kinds == nil)
        #expect(ItoRunner.compatibility(of: abi2, supported: 1...3) == .invalid)
        #expect(ItoRunner.compatibility(of: abi3) == .invalid)
        #expect(ItoRunner.compatibility(of: abi2) == .pluginTooOld(abi: 2))
    }

    @Test func aNewerPluginIsJudgedByItsKindsOnlyOnceTheRangeCoversIt() throws {
        let binary = try ItoRunner.inspectBinary(wasm(abiExport(4) + kindsExport(1) + errorExport(2)))

        #expect(ItoRunner.compatibility(of: binary, supported: 3...4) == .compatible)
        #expect(ItoRunner.compatibility(of: binary) == .pluginTooNew(abi: 4))
    }

    @Test func aNewerPluginIsReportedByItsABIWhateverItsKindsExportHolds() async throws {
        let unknownBit = try wasm(abiExport(4) + kindsExport(8))
        let nonConstant = try wasm(abiExport(4)
            + #"(func (export "ito_supported_kinds") (result i32) i32.const 1 i32.const 1 i32.or)"#)

        for module in [unknownBit, nonConstant] {
            let binary = try ItoRunner.inspectBinary(module)
            #expect(binary.abiVersion == 4)
            #expect(binary.kinds == nil)
            #expect(ItoRunner.compatibility(of: binary) == .pluginTooNew(abi: 4))
            await #expect(throws: ItoError.unsupportedABI(version: 4, supported: 3...3)) {
                try await ItoRunner().loadPlugin(fromBytes: module)
            }
        }
    }

    @Test func aKindsExportThatIsNotAUsableFunctionLeavesKindsUnreadAndTheFileInvalid() throws {
        let unusable = [
            #"(func (export "ito_supported_kinds") (param i32) (result i32) i32.const 1)"#,
            #"(func (export "ito_supported_kinds") (result i64) i64.const 1)"#,
            #"(func (export "ito_supported_kinds") (result i32 i32) i32.const 1 i32.const 1)"#,
            #"(func (export "ito_supported_kinds") i32.const 1 drop)"#,
            #"(global (export "ito_supported_kinds") i32 (i32.const 1))"#,
            #"(import "env" "kinds" (func $kinds (result i32))) (export "ito_supported_kinds" (func $kinds))"#
        ]
        for export in unusable {
            let binary = try ItoRunner.inspectBinary(wasm(export + abiExport(3) + errorExport(2)))
            #expect(binary.kinds == nil, Comment(rawValue: export))
            #expect(ItoRunner.compatibility(of: binary) == .invalid, Comment(rawValue: export))
        }
    }

    @Test func anABIExportWithAnotherSignatureIsRefused() throws {
        let exports = [
            #"(func (export "ito_abi_version") (param i32) (result i32) i32.const 2)"#,
            #"(func (export "ito_abi_version") (result i64) i64.const 2)"#,
            #"(func (export "ito_abi_version") i32.const 2 drop)"#
        ]
        for export in exports {
            let module = try wasm(export)
            #expect(throws: ItoError.self, Comment(rawValue: export)) { try ItoRunner.inspectBinary(module) }
        }
    }

    @Test func theErrorVersionIsTheConstantTheExportReturnsOr1WithoutIt() throws {
        let absent = try ItoRunner.inspectBinary(wasm(abiExport(2)))
        let declared = try ItoRunner.inspectBinary(
            wasm(#"(func (export "ito_error_version") (result i32) i32.const 2)"#))

        #expect(absent.errorProtocolVersion == 1)
        #expect(declared.errorProtocolVersion == 2)
    }

    @Test func anErrorVersionThatIsNotAPositiveDefinedConstantFunctionIsRefused() throws {
        let exports = [
            #"(func (export "ito_error_version") (result i32) i32.const 0)"#,
            #"(func (export "ito_error_version") (result i32) i32.const -1)"#,
            #"(func (export "ito_error_version") (result i64) i64.const 2)"#,
            #"(func (export "ito_error_version") (result i32) i32.const 1 i32.const 1 i32.add)"#,
            #"(import "env" "v" (func $v (result i32))) (export "ito_error_version" (func $v))"#,
            #"(global (export "ito_error_version") i32 (i32.const 2))"#
        ]
        for export in exports {
            let module = try wasm(export)
            #expect(throws: ItoError.self, Comment(rawValue: export)) { try ItoRunner.inspectBinary(module) }
        }
    }

    // MARK: Imports

    @Test func importsAreListedSortedOnceEachAndIncludeNonFunctions() throws {
        let binary = try ItoRunner.inspectBinary(wasm("""
            (import "ito:core/net" "fetch_v2" (func (param i32 i32 i32 i32) (result i32)))
            (import "ito:core/html" "parse" (func (param i32 i32) (result i32)))
            (import "ito:core/net" "fetch_v2" (func (param i32 i32 i32 i32) (result i32)))
            (import "env" "memory" (memory 1))
            """))

        #expect(binary.imports == ["env.memory", "ito:core/html.parse", "ito:core/net.fetch_v2"])
    }

    // MARK: Start section

    @Test func aStartSectionIsReportedAndTheABIIsStillRead() throws {
        let binary = try ItoRunner.inspectBinary(wasm("""
            (func $init)
            (start $init)
            \(abiExport(3))
            """))

        #expect(binary.hasStartSection)
        #expect(binary.abiVersion == 3)
    }

    // MARK: Compatibility

    /// An interface as `inspectBinary` reports one that `loadPlugin` could run: from ABI 2 on a
    /// module names its kinds, and it declares the error-report version the runner reads.
    private func interface(
        _ abi: Int, imports: [String] = [], kinds: [MediaKind]? = nil, hasStartSection: Bool = false,
        errorProtocolVersion: UInt32 = 2
    ) -> PluginBinaryInterface {
        PluginBinaryInterface(
            abiVersion: abi, imports: imports, kinds: kinds ?? (abi >= 2 ? [.manga] : nil),
            hasStartSection: hasStartSection, errorProtocolVersion: errorProtocolVersion)
    }

    @Test func theABIRangeIsInclusiveAndDirectionIsPreserved() {
        func compatibility(_ abi: Int, _ supported: ClosedRange<Int>) -> PluginBinaryCompatibility {
            ItoRunner.compatibility(of: interface(abi), supported: supported)
        }

        #expect(compatibility(2, 2...4) == .compatible)
        #expect(compatibility(4, 2...4) == .compatible)
        #expect(compatibility(3, 3...3) == .compatible)
        #expect(compatibility(1, 2...4) == .pluginTooOld(abi: 1))
        #expect(compatibility(0, 1...2) == .pluginTooOld(abi: 0))
        #expect(compatibility(5, 2...4) == .pluginTooNew(abi: 5))
        #expect(compatibility(3, 1...2) == .pluginTooNew(abi: 3))
        #expect(compatibility(2, 3...3) == .pluginTooOld(abi: 2))
        #expect(compatibility(4, 3...3) == .pluginTooNew(abi: 4))
    }

    @Test func theDefaultRangeIsABI3Only() {
        #expect(ItoRunner.supportedABIVersions == 3...3)
        #expect(ItoRunner.compatibility(of: interface(3)) == .compatible)
        // Absent (read as 1), 1, 2 and 4 are each refused, with the direction kept.
        for abi in [0, 1, 2] {
            #expect(ItoRunner.compatibility(of: interface(abi)) == .pluginTooOld(abi: abi))
        }
        #expect(ItoRunner.compatibility(of: interface(4)) == .pluginTooNew(abi: 4))
    }

    @Test func theLayoutABIOfSharedPayloadsIsTheOneABIThatRuns() {
        #expect(ItoRunner.supportedABIVersions == sharedLayoutABIVersion...sharedLayoutABIVersion)
    }

    @Test func importsTheRunnerLacksAreNamedOnceAndHostFunctionsAreAccepted() {
        let missing = interface(
            3, imports: ["ito:core/net.fetch_v2", "ito:core/net.fetch_v9", "ito:core/std.print", "wasi.fd_write"])

        #expect(ItoRunner.compatibility(of: missing) == .missingImports(["ito:core/net.fetch_v9", "wasi.fd_write"]))
        #expect(ItoRunner.compatibility(of: interface(3, imports: ["ito:core/net.fetch_v2", "ito:core/std.print"]))
            == .compatible)
    }

    @Test func aNewerABIIsReportedBeforeMissingImports() {
        let binary = interface(4, imports: ["ito:core/net.fetch_v9"])

        #expect(ItoRunner.compatibility(of: binary) == .pluginTooNew(abi: 4))
        #expect(ItoRunner.compatibility(of: binary, supported: 3...4) == .missingImports(["ito:core/net.fetch_v9"]))
    }

    @Test func aStartSectionIsInvalidWhateverTheABI() {
        for abi in [1, 2, 3] {
            let binary = interface(abi, hasStartSection: true)
            #expect(ItoRunner.compatibility(of: binary, supported: 1...3) == .invalid)
        }
    }

    @Test func anErrorReportVersionBelow2IsInvalidAfterTheDirectionChecks() throws {
        #expect(ItoRunner.compatibility(of: interface(3, errorProtocolVersion: 1)) == .invalid)
        #expect(ItoRunner.compatibility(of: interface(3, errorProtocolVersion: 2)) == .compatible)
        #expect(ItoRunner.compatibility(of: interface(3, errorProtocolVersion: 3)) == .compatible)
        #expect(ItoRunner.compatibility(of: interface(4, errorProtocolVersion: 1)) == .pluginTooNew(abi: 4))
        // A module that lacks the export reads as version 1.
        let absent = try ItoRunner.inspectBinary(wasm(abiExport(3) + kindsExport(1)))
        let declared = try ItoRunner.inspectBinary(wasm(abiExport(3) + kindsExport(1) + errorExport(2)))
        #expect(ItoRunner.compatibility(of: absent) == .invalid)
        #expect(ItoRunner.compatibility(of: declared) == .compatible)
    }

    @Test func fromABI2AModuleWithoutReadableKindsIsInvalidAfterTheDirectionChecks() throws {
        let withoutKinds = try ItoRunner.inspectBinary(wasm(abiExport(3) + errorExport(2)))
        let withKinds = try ItoRunner.inspectBinary(wasm(abiExport(3) + kindsExport(1) + errorExport(2)))
        let abi1 = try ItoRunner.inspectBinary(wasm(abiExport(1)))

        #expect(ItoRunner.compatibility(of: withoutKinds) == .invalid)
        #expect(ItoRunner.compatibility(of: withKinds) == .compatible)
        #expect(ItoRunner.compatibility(of: abi1) == .pluginTooOld(abi: 1))
        // The direction is reported first when the runner doesn't support the plugin's ABI.
        #expect(ItoRunner.compatibility(of: withoutKinds, supported: 4...4) == .pluginTooOld(abi: 3))
        #expect(ItoRunner.compatibility(of: withoutKinds, supported: 1...2) == .pluginTooNew(abi: 3))
    }

    // MARK: Loading

    private static let printingPlugin = """
        (import "ito:core/std" "print" (func $print (param i32 i32)))
        (memory (export "memory") 1)
        (data (i32.const 16) "ran")
        (func (export "alloc") (param i32) (result i32) i32.const 1024)
        (func (export "dealloc") (param i32 i32))
        (func $init (call $print (i32.const 16) (i32.const 3)))
        (func (export "run") (call $init))
        """

    @Test func aStartSectionIsRefusedBeforeItsStartFunctionRuns() async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)

        await #expect(throws: ItoError.self) {
            try await runner.loadPlugin(fromBytes: wasm(Self.printingPlugin + abi3Prelude() + "\n(start $init)"))
        }

        #expect(std.messages.isEmpty)
    }

    /// Without this the refusal above could pass because the start function never runs at all.
    @Test func theSameStartFunctionRunsWhenTheModuleIsInstantiatedDirectly() throws {
        let std = RecordingStdModule()
        let bridge = WasmBridge()
        bridge.stdModule = std
        let store = Store(engine: Engine())
        let module = try parseWasm(bytes: wasm(Self.printingPlugin + "\n(start $init)"))
        let imports = WasmBridge.imports(from: bridge.buildImportTable(store: store))

        _ = try module.instantiate(store: store, imports: imports)

        #expect(std.messages == ["ran"])
    }

    @Test func theSameModuleWithoutAStartSectionLoadsAndOnlyRunsWhenAsked() async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)

        try await runner.loadPlugin(fromBytes: wasm(Self.printingPlugin + abi3Prelude()))
        #expect(std.messages.isEmpty)

        _ = try await runner.executeExport("run", args: [])
        #expect(std.messages == ["ran"])
    }

    @Test func aRefusedPluginLeavesThePreviouslyLoadedOneInPlace() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wasm(Self.printingPlugin + abi3Prelude(kinds: 4)))

        await #expect(throws: ItoError.self) {
            try await runner.loadPlugin(fromBytes: wasm(Self.printingPlugin + abi3Prelude() + "\n(start $init)"))
        }

        #expect(await runner.abiVersion == 3)
        #expect(await runner.supportedKinds == [.novel])
    }

    @Test func anUnsupportedABIIsRefusedByDirectionEvenWhenItAlsoLacksImports() async throws {
        let newer = try wasm("""
            (import "ito:core/net" "fetch_v9" (func))
            (memory (export "memory") 1)
            \(abiExport(4))
            """)
        let older = try wasm("(memory (export \"memory\") 1)\n\(abiExport(0))")

        await #expect(throws: ItoError.unsupportedABI(version: 4, supported: 3...3)) {
            try await ItoRunner().loadPlugin(fromBytes: newer)
        }
        await #expect(throws: ItoError.unsupportedABI(version: 0, supported: 3...3)) {
            try await ItoRunner().loadPlugin(fromBytes: older)
        }
    }

    /// The plugin would run code if it were instantiated: its export prints. Refusing it for its
    /// ABI, whether it declares one or not, happens before that.
    @Test(arguments: [nil, 1, 2, 4] as [Int?])
    func everyABIButThreeIsRefusedBeforeAnyPluginCodeRuns(_ abi: Int?) async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)
        let module = try wasm("""
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "ran")
            \(abi.map { abiExport($0) } ?? "")
            \(kindsExport(1))
            \(errorExport(2))
            (func (export "get_home") (result i64) (call $print (i32.const 16) (i32.const 3)) i64.const 0)
            """)

        await #expect(throws: ItoError.unsupportedABI(version: abi ?? 1, supported: 3...3)) {
            try await runner.loadPlugin(fromBytes: module)
        }

        #expect(std.messages.isEmpty)
        #expect(await runner.abiVersion == 0, "nothing was loaded")
    }

    @Test(arguments: [nil, 1] as [Int?])
    func anErrorReportVersionBelowTwoIsRefusedBeforeAnyPluginCodeRuns(_ version: Int?) async throws {
        func module(errorVersion: String) throws -> [UInt8] {
            try wasm("""
                (import "ito:core/std" "print" (func $print (param i32 i32)))
                (memory (export "memory") 1)
                (data (i32.const 16) "ran")
                \(abiExport(3))
                \(kindsExport(1))
                \(errorVersion)
                (func (export "get_home") (result i64) (call $print (i32.const 16) (i32.const 3)) i64.const 0)
                """)
        }
        // The same module loads once it declares version 2, so the version alone is what refuses it.
        let control = ItoRunner()
        try await control.loadPlugin(fromBytes: module(errorVersion: errorExport(2)))
        #expect(await control.abiVersion == 3)

        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)
        await #expect(throws: ItoError.wasmTrap(
            "ito_error_version must be at least 2: the plugin reports failures in a format this host no longer reads."
        )) { try await runner.loadPlugin(fromBytes: module(errorVersion: version.map { errorExport($0) } ?? "")) }

        #expect(std.messages.isEmpty)
        #expect(await runner.abiVersion == 0, "nothing was loaded")
    }

    @Test func laterErrorReportVersionsLoad() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wasm(
            #"(memory (export "memory") 1)"# + abiExport(3) + kindsExport(1) + errorExport(7)))
        #expect(await runner.abiVersion == 3)
    }

    @Test func aNonConstantABIExportIsRefusedWithoutCallingIt() async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)
        let module = try wasm("""
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "ran")
            (func (export "ito_abi_version") (result i32)
                (call $print (i32.const 16) (i32.const 3))
                i32.const 3)
            \(kindsExport(1))
            \(errorExport(2))
            """)

        await #expect(throws: ItoError.self) { try await runner.loadPlugin(fromBytes: module) }

        #expect(std.messages.isEmpty)
    }

    @Test func aNonConstantKindsExportIsRefusedWithoutCallingIt() async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)
        let module = try wasm("""
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "ran")
            \(abiExport(3))
            \(errorExport(2))
            (func (export "ito_supported_kinds") (result i32)
                (call $print (i32.const 16) (i32.const 3))
                i32.const 1)
            """)

        await #expect(throws: ItoError.self) { try await runner.loadPlugin(fromBytes: module) }

        #expect(std.messages.isEmpty)
    }

    @Test func aNonConstantErrorVersionExportIsRefusedWithoutCallingIt() async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)
        let module = try wasm("""
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "ran")
            \(abiExport(3))
            \(kindsExport(1))
            (func (export "ito_error_version") (result i32)
                (call $print (i32.const 16) (i32.const 3))
                i32.const 2)
            """)

        await #expect(throws: ItoError.self) { try await runner.loadPlugin(fromBytes: module) }

        #expect(std.messages.isEmpty)
    }

    @Test func aKindsMaskNamingAnUnknownKindIsRefusedBeforeInstantiation() async throws {
        let std = RecordingStdModule()
        let runner = ItoRunner()
        await runner.setStdModule(std)
        let module = try wasm("""
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "ran")
            \(abiExport(3))
            \(errorExport(2))
            \(kindsExport(8))
            (func (export "get_listing") (param i32 i32 i32) (result i64)
                (call $print (i32.const 16) (i32.const 3))
                i64.const 0)
            """)

        // The static refusal, not the post-load comparison, which would report the kinds it read.
        await #expect(throws: ItoError.wasmTrap(
            "ito_supported_kinds must be a defined () -> i32 returning a constant that names kinds this host knows."
        )) { try await runner.loadPlugin(fromBytes: module) }

        #expect(std.messages.isEmpty)
    }

    // MARK: Bundles

    private static func manifestBytes(id: String = "test.bundle") throws -> [UInt8] {
        let info = PluginInfo(
            id: id, name: "Bundle", version: "1", minAppVersion: "1.0.0", type: .novel, kinds: [.novel])
        return [UInt8](try JSONEncoder().encode(PluginManifest(info: info)))
    }

    private static func module() throws -> [UInt8] {
        try wasm("""
            (import "ito:core/std" "print" (func (param i32 i32)))
            (memory (export "memory") 1)
            \(abiExport(3))
            \(kindsExport(4))
            \(errorExport(2))
            """)
    }

    private static let expectedBinary = PluginBinaryInterface(
        abiVersion: 3, imports: ["ito:core/std.print"], kinds: [.novel], errorProtocolVersion: 2)

    @Test func aBundleIsInspectedWithoutBeingLoaded() throws {
        let url = try zipFile([.stored("manifest.json", Self.manifestBytes()), .stored("main.wasm", Self.module())])
        defer { try? FileManager.default.removeItem(at: url) }

        let (manifest, binary) = try ItoRunner.inspectBundle(at: url)

        #expect(manifest.info.id == "test.bundle")
        #expect(binary == Self.expectedBinary)
    }

    @Test func aDeflatedBundleLikeThePackagersIsInspectedLoadedAndItsInfoExtracted() async throws {
        let icon: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let url = try zipFile([
            .deflated("main.wasm", Self.module()), .deflated("manifest.json", Self.manifestBytes()),
            .deflated("icon.png", icon)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let (manifest, binary) = try ItoRunner.inspectBundle(at: url)
        let info = try ItoRunner.extractPluginInfo(from: url)
        let loaded = try await ItoRunner().loadBundle(from: url)

        #expect(manifest.info.id == "test.bundle")
        #expect(binary == Self.expectedBinary)
        #expect(info.manifest.info.id == "test.bundle")
        #expect(info.icon == Data(icon))
        #expect(loaded?.info.id == "test.bundle")
    }

    @Test func aBundleWithoutAModuleStillYieldsItsManifest() throws {
        let url = try zipFile([.stored("manifest.json", Self.manifestBytes())])
        defer { try? FileManager.default.removeItem(at: url) }

        let (manifest, binary) = try ItoRunner.inspectBundle(at: url)

        #expect(manifest.info.id == "test.bundle")
        #expect(binary == nil)
    }

    /// Each damage is on the module, which comes first in the archive, so a reader that stopped at
    /// the first bad entry would lose the manifest after it.
    @Test func aDamagedModuleLeavesTheBinaryNilAndNeverDropsTheBundle() async throws {
        let module = try Self.module()
        var unknownMethod = ZipFixtureEntry.stored("main.wasm", module)
        unknownMethod.method = 99
        var corruptStream = ZipFixtureEntry.deflated("main.wasm", module)
        corruptStream.payload = [UInt8](repeating: 0xFF, count: 16)
        corruptStream.compressedSize = 16
        var sizePastTheEnd = ZipFixtureEntry.stored("main.wasm", module)
        sizePastTheEnd.compressedSize = 1_000_000
        sizePastTheEnd.uncompressedSize = 1_000_000
        var wrongChecksum = ZipFixtureEntry.stored("main.wasm", module)
        wrongChecksum.checksum ^= 1
        var tooLarge = ZipFixtureEntry.stored("main.wasm", module)
        tooLarge.uncompressedSize = UInt32(PluginBundle.wasmByteLimit + 1)

        let cases = ["unknown method": unknownMethod, "corrupt stream": corruptStream,
                     "size past the end": sizePastTheEnd, "wrong checksum": wrongChecksum, "too large": tooLarge]
        for (name, damaged) in cases {
            let url = try zipFile([damaged, .stored("manifest.json", Self.manifestBytes())])
            defer { try? FileManager.default.removeItem(at: url) }

            let (manifest, binary) = try ItoRunner.inspectBundle(at: url)
            #expect(manifest.info.id == "test.bundle", Comment(rawValue: name))
            #expect(binary == nil, Comment(rawValue: name))
            // Loading needs the module, so it can't hide the damage; reading the info doesn't.
            await #expect(throws: ItoError.self, Comment(rawValue: name)) { try await ItoRunner().loadBundle(from: url) }
            #expect(try ItoRunner.extractPluginInfo(from: url).manifest.info.id == "test.bundle")
        }
    }

    @Test func aModuleThatIsNotAModuleLeavesTheBinaryNil() throws {
        let url = try zipFile([.stored("main.wasm", [1, 2, 3]), .stored("manifest.json", Self.manifestBytes())])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ItoRunner.inspectBundle(at: url).binary == nil)
    }

    @Test func aManifestThatIsMissingOversizedOrUndecodableThrows() throws {
        var oversized = ZipFixtureEntry.stored("manifest.json", try Self.manifestBytes())
        oversized.uncompressedSize = UInt32(PluginBundle.manifestByteLimit + 1)
        let archives = [
            try zipFile([.stored("main.wasm", Self.module())]),
            try zipFile([oversized, .stored("main.wasm", Self.module())]),
            try zipFile([.stored("manifest.json", Array("{".utf8)), .stored("main.wasm", Self.module())])
        ]
        let notZip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ito")
        try Data("not an archive".utf8).write(to: notZip)
        defer { (archives + [notZip]).forEach { try? FileManager.default.removeItem(at: $0) } }

        for url in archives + [notZip] {
            #expect(throws: (any Error).self) { try ItoRunner.inspectBundle(at: url) }
            #expect(throws: (any Error).self) { try ItoRunner.extractPluginInfo(from: url) }
        }
    }

    @Test func entriesAreMatchedByTheNamesPackagersWriteWithLegacyNamesAtAnyDepthAsAFallback() throws {
        let legacy = try zipFile([.stored("plugin.json", Self.manifestBytes(id: "legacy")), .stored("plugin.wasm", Self.module())])
        let fixedNamesWin = try zipFile([
            .stored("plugin.json", Self.manifestBytes(id: "legacy")), .stored("plugin.wasm", [1, 2, 3]),
            .stored("manifest.json", Self.manifestBytes(id: "fixed")), .stored("main.wasm", Self.module())
        ])
        let nested = try zipFile([
            .stored("manifest.json", Self.manifestBytes()), .stored("other/plugin.wasm", Self.module()),
            .stored("__MACOSX/main.wasm", [1, 2, 3])
        ])
        let onlyResourceForks = try zipFile([
            .stored("manifest.json", Self.manifestBytes()), .stored("__MACOSX/main.wasm", Self.module()),
            .stored("Plugin/__MACOSX/plugin.wasm", Self.module())
        ])
        defer { [legacy, fixedNamesWin, nested, onlyResourceForks].forEach { try? FileManager.default.removeItem(at: $0) } }

        let legacyRead = try ItoRunner.inspectBundle(at: legacy)
        let fixedRead = try ItoRunner.inspectBundle(at: fixedNamesWin)
        let nestedRead = try ItoRunner.inspectBundle(at: nested)
        let forksRead = try ItoRunner.inspectBundle(at: onlyResourceForks)

        #expect(legacyRead.manifest.info.id == "legacy" && legacyRead.binary == Self.expectedBinary)
        #expect(fixedRead.manifest.info.id == "fixed" && fixedRead.binary == Self.expectedBinary)
        #expect(nestedRead.binary == Self.expectedBinary)
        #expect(forksRead.binary == nil)
    }

    /// A bundle zipped from inside its folder has every entry under that folder, and Finder adds
    /// resource forks for each file. It was listed before, so it must stay listed.
    @Test func aBundleZippedInsideAFolderIsStillListedInspectedAndLoaded() async throws {
        let icon: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let url = try zipFile([
            .stored("Plugin/manifest.json", Self.manifestBytes()), .stored("Plugin/main.wasm", Self.module()),
            .stored("Plugin/icon.png", icon),
            .stored("__MACOSX/Plugin/._manifest.json", [0, 5, 22]), .stored("__MACOSX/Plugin/._main.wasm", [0, 5, 22]),
            .stored("__MACOSX/Plugin/._icon.png", [0, 5, 22])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let (manifest, binary) = try ItoRunner.inspectBundle(at: url)
        let info = try ItoRunner.extractPluginInfo(from: url)
        let loaded = try await ItoRunner().loadBundle(from: url)

        #expect(manifest.info.id == "test.bundle")
        #expect(binary == Self.expectedBinary)
        #expect(info.manifest.info.id == "test.bundle")
        #expect(info.icon == Data(icon))
        #expect(loaded?.info.id == "test.bundle")
    }

    /// The declared size is the archive's claim: a stream that inflates past the limit is stopped
    /// even when the entry declares less.
    @Test func anEntryThatInflatesPastTheLimitIsStoppedWhateverItDeclares() throws {
        var lying = ZipFixtureEntry.deflated("main.wasm", [UInt8](repeating: 7, count: 100))
        lying.uncompressedSize = 10
        let url = try zipFile([lying, .stored("manifest.json", Self.manifestBytes())])
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try PluginBundle(at: url)

        #expect(throws: ItoError.wasmTrap("main.wasm in the .ito archive is larger than 50 bytes.")) {
            try bundle.wasm(limit: 50)
        }
    }
}

// MARK: - Fixture archive

/// One entry of a fixture archive: the bytes written for it and what its headers claim about them.
/// Tests damage an entry by changing a field after building it with `stored` or `deflated`.
private struct ZipFixtureEntry {
    var name: String
    var payload: [UInt8]
    var method: UInt16
    var checksum: UInt32
    var compressedSize: UInt32
    var uncompressedSize: UInt32

    static func stored(_ name: String, _ data: [UInt8]) -> ZipFixtureEntry {
        ZipFixtureEntry(
            name: name, payload: data, method: 0, checksum: crc32(data),
            compressedSize: UInt32(data.count), uncompressedSize: UInt32(data.count))
    }

    /// A raw deflate stream of stored blocks, which is a valid stream any inflater reads.
    static func deflated(_ name: String, _ data: [UInt8]) -> ZipFixtureEntry {
        var stream: [UInt8] = []
        let blocks = stride(from: 0, to: max(data.count, 1), by: 0xFFFF).map { data[$0..<min($0 + 0xFFFF, data.count)] }
        for (index, block) in blocks.enumerated() {
            let length = UInt16(block.count)
            stream.append(index == blocks.count - 1 ? 1 : 0)
            stream += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
            stream += block
        }
        return ZipFixtureEntry(
            name: name, payload: stream, method: 8, checksum: crc32(data),
            compressedSize: UInt32(stream.count), uncompressedSize: UInt32(data.count))
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// Writes `entries`, in order, as a zip archive to a temporary file.
private func zipFile(_ entries: [ZipFixtureEntry]) throws -> URL {
    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<(T.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    var archive: [UInt8] = []
    var directory: [UInt8] = []
    for entry in entries {
        let nameBytes = Array(entry.name.utf8)
        let dosDate: UInt16 = 33  // 1980-01-01
        // Central directory record.
        directory += le(UInt32(0x0201_4B50))
        directory += le(UInt16(20)) + le(UInt16(20))  // version made by, version needed
        directory += le(UInt16(0)) + le(entry.method)  // flags, method
        directory += le(UInt16(0)) + le(dosDate)  // time, date
        directory += le(entry.checksum) + le(entry.compressedSize) + le(entry.uncompressedSize)
        directory += le(UInt16(nameBytes.count)) + le(UInt16(0)) + le(UInt16(0))  // name, extra, comment
        directory += le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0))  // disk, internal and external attributes
        directory += le(UInt32(archive.count))
        directory += nameBytes
        // Local file header, then the data.
        archive += le(UInt32(0x0403_4B50))
        archive += le(UInt16(20)) + le(UInt16(0)) + le(entry.method)  // version needed, flags, method
        archive += le(UInt16(0)) + le(dosDate)
        archive += le(entry.checksum) + le(entry.compressedSize) + le(entry.uncompressedSize)
        archive += le(UInt16(nameBytes.count)) + le(UInt16(0))
        archive += nameBytes
        archive += entry.payload
    }
    let directoryOffset = archive.count
    archive += directory
    archive += le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0))
    archive += le(UInt16(entries.count)) + le(UInt16(entries.count))
    archive += le(UInt32(directory.count)) + le(UInt32(directoryOffset)) + le(UInt16(0))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ito")
    try Data(archive).write(to: url)
    return url
}

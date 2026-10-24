import Foundation
import XCTest
import WAT
import WasmKit
@testable import ito_runner

private final class LifetimeDefaults: DefaultsModule, @unchecked Sendable {
    private let lock = NSLock()
    private var values = ["fixture": "memory-only"]
    private let released: (@Sendable () -> Void)?
    init(released: (@Sendable () -> Void)? = nil) { self.released = released }
    deinit { released?() }
    func get(key: String) -> String? { lock.withLock { values[key] } }
    func set(key: String, value: String) { lock.withLock { values[key] = value } }
    func setSecret(key: String, value: String) { set(key: key, value: value) }
    func remove(key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}

final class RunnerLifetimeTests: XCTestCase {
    func testDroppingALoadedRunnerReleasesItsMemorySettings() async throws {
        let released = expectation(description: "Runner settings released")
        var runner: ItoRunner? = ItoRunner()
        do {
            let defaults = LifetimeDefaults { released.fulfill() }
            await runner!.setDefaultsModule(defaults)
        }
        try await runner!.loadPlugin(fromBytes: wat2wasm(#"(module (memory (export "memory") 1))"#))
        runner = nil
        await fulfillment(of: [released], timeout: 2)
    }

    func testStandaloneHostCallbacksKeepTheirCodecsButNotTheActor() throws {
        var runner: ItoRunner? = ItoRunner()
        let runnerWasReleased = { [weak runner] in runner == nil }
        let bridge = WasmBridge(runner: runner!)
        bridge.defaultsModule = LifetimeDefaults()
        runner = nil
        XCTAssertTrue(runnerWasReleased())

        let engine = Engine()
        let store = Store(engine: engine)
        let module = try parseWasm(bytes: wat2wasm(#"""
        (module
          (import "ito:core/defaults" "get" (func $get (param i32 i32) (result i64)))
          (memory (export "memory") 1)
          (data (i32.const 128) "fixture")
          (func (export "alloc") (param i32) (result i32) i32.const 256)
          (func (export "read") (result i64) i32.const 128 i32.const 7 call $get))
        """#))
        let instance = try module.instantiate(
            store: store, imports: WasmBridge.imports(from: bridge.buildImportTable(store: store))
        )
        defer { withExtendedLifetime((engine, store, module, bridge)) {} }
        let read = try XCTUnwrap(instance.exports[function: "read"])
        guard case .i64(let packed)? = try read([]).first else {
            XCTFail("Expected packed defaults response")
            return
        }
        let memory = try XCTUnwrap(instance.exports[memory: "memory"])
        let bytes = memory.withUnsafeMutableBufferPointer(
            offset: UInt(packed >> 32), count: Int(packed & 0xffff_ffff)
        ) { Array($0) }
        let value = try ItoPostcardDecoder().decode(String?.self, from: bytes)
        XCTAssertEqual(value, "memory-only")
    }
}

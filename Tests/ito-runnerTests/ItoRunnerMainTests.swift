import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

@Suite("Ito Runner - Main API Tests")
struct ItoRunnerMainTests {
    @Test("Load Basic Plugin and Execute Export")
    func testLoadAndExecute() async throws {
        // A minimal WAT that exports 'alloc' and 'memory'
        let wat = """
            (module
                (memory (export "memory") 1)
                (func (export "alloc") (param i32) (result i32)
                    i32.const 42 ;; Returning a dummy pointer
                )
                (func (export "add") (param i32 i32) (result i32)
                    local.get 0
                    local.get 1
                    i32.add
                )
            )
            """

        let wasmBytes = try wat2wasm(wat)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "test_plugin.wasm")
        try Data(wasmBytes).write(to: tempURL)

        let runner = ItoRunner()
        try await runner.loadPlugin(from: tempURL)

        // Test memory reading
        let pointer = 42
        try await runner.writeMemory(offset: pointer, bytes: [0x01, 0x02, 0x03])
        let readBack = try await runner.readMemory(offset: pointer, length: 3)
        #expect(readBack == [0x01, 0x02, 0x03])

        // Test execute export generic
        let result = try await runner.executeExport("add", args: [.i32(10), .i32(5)])
        #expect(result.count == 1)
        if case .i32(let val) = result[0] {
            #expect(val == 15)
        } else {
            Issue.record("Expected i32 result")
        }

        // Clean up
        try FileManager.default.removeItem(at: tempURL)
    }
}

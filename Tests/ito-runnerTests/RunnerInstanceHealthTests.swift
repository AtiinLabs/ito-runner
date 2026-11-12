import Foundation
import Testing
import WAT
import WasmKit
@testable import ito_runner

enum HealthFault: CaseIterable, Sendable {
    case trap, memory
}

private extension ItoRunner {
    /// Parks on the execution queue, not the cooperative pool. The test chooses which side of
    /// cancellation the actual guest trap or memory access happens on.
    func gatedHealthFault(_ fault: HealthFault, faultFirst: Bool,
                          policyFirst: Bool? = nil,
                          entered: AsyncStream<Void>.Continuation,
                          release: DispatchSemaphore) async throws {
        let bridge = self.bridge
        try await performSerialized(context: .test) {
            let fail = {
                switch fault {
                case .trap: _ = try self.executeExport("crash")
                case .memory: _ = try self.readMemory(offset: 65536, length: 1)
                }
            }
            let earlyResult: Result<Void, any Error>? = faultFirst ? Result { try fail() } : nil
            if policyFirst == true { bridge?.activeCallToken?.recordPolicyOutcome(.hardUserBlocked) }
            entered.yield()
            release.wait()
            if policyFirst == false { bridge?.activeCallToken?.recordPolicyOutcome(.hardUserBlocked) }
            if let earlyResult { try earlyResult.get() }
            else { try fail() }
        }
    }

    // The signal is sent on the actor immediately before synchronous enqueue. Entering the actor
    // again after receiving it proves this job is queued, rather than relying on task scheduling.
    func healthProbe(enqueued: AsyncStream<Void>.Continuation? = nil) async throws -> Bool {
        enqueued?.yield()
        return try await performSerialized(context: .test) {
            try self.executeExport("probe") == [.i32(1)]
        }
    }

    func healthEnqueueBarrier() {}

    func healthNonCrash(_ error: ItoError) async throws {
        try await performSerialized(context: .test) { throw error }
    }
}

@Suite("Runner instance health", .timeLimit(.minutes(1)))
struct RunnerInstanceHealthTests {
    private static func wasm() throws -> [UInt8] {
        try wat2wasm("""
            (module
                \(abi3Prelude())
                (memory (export "memory") 1)
                (global $calls (mut i32) (i32.const 0))
                (func (export "crash") unreachable)
                (func (export "probe") (result i32)
                    global.get $calls i32.const 1 i32.add global.set $calls
                    i32.const 1)
                (func (export "probe_calls") (result i32) global.get $calls))
            """)
    }

    private static func runner() async throws -> ItoRunner {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wasm())
        return runner
    }

    private func retainedFailure(_ runner: ItoRunner, fault: HealthFault) async -> ItoError? {
        do {
            _ = try await runner.healthProbe()
            Issue.record("A failed instance executed another job")
            return nil
        } catch let error as ItoError {
            #expect(error.isCrash)
            switch fault {
            case .trap:
                if case .wasmTrap = error {} else { Issue.record("Expected the retained guest trap") }
            case .memory:
                #expect(error == .memoryOutOfBounds(offset: 65536, length: 1, memorySize: 65536))
            }
            return error
        } catch {
            Issue.record("Expected the retained ItoError crash")
            return nil
        }
    }

    @Test(arguments: [false, true], HealthFault.allCases)
    func cancellationHidesTheCrashButRetiresQueuedAndLaterCalls(faultFirst: Bool, fault: HealthFault) async throws {
        let runner = try await Self.runner()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            try await runner.gatedHealthFault(fault, faultFirst: faultFirst,
                entered: entered.continuation, release: release)
        }
        var start = entered.stream.makeAsyncIterator()
        _ = await start.next()
        let enqueued = AsyncStream<Void>.makeStream()
        let queued = Task { try await runner.healthProbe(enqueued: enqueued.continuation) }
        var enqueue = enqueued.stream.makeAsyncIterator()
        _ = await enqueue.next()
        await runner.healthEnqueueBarrier()
        let cancelledEnqueued = AsyncStream<Void>.makeStream()
        let cancelledQueued = Task { try await runner.healthProbe(enqueued: cancelledEnqueued.continuation) }
        var cancelledEnqueue = cancelledEnqueued.stream.makeAsyncIterator()
        _ = await cancelledEnqueue.next()
        await runner.healthEnqueueBarrier()
        cancelledQueued.cancel()
        first.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await cancelledQueued.value }
        let failure = try #require(await retainedFailure(runner, fault: fault))
        await #expect(throws: failure) { try await queued.value }
        #expect(try await runner.executeExport("probe_calls") == [.i32(0)])

        // Failed loading cannot revive the retired generation.
        await #expect(throws: (any Error).self) { try await runner.loadPlugin(fromBytes: [1, 2, 3]) }
        await #expect(throws: failure) { try await runner.healthProbe() }

        let replacement = try await Self.runner()
        #expect(try await replacement.healthProbe())
        // Publishing a successfully loaded generation is the only way to clear this runner's failure.
        try await runner.loadPlugin(fromBytes: Self.wasm())
        #expect(try await runner.healthProbe())
    }

    @Test(arguments: [false, true], HealthFault.allCases)
    func policyCancellationPrecedenceDoesNotHideInstanceHealth(policyFirst: Bool, fault: HealthFault) async throws {
        let runner = try await Self.runner()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let call = Task {
            try await runner.gatedHealthFault(fault, faultFirst: false, policyFirst: policyFirst,
                entered: entered.continuation, release: release)
        }
        var start = entered.stream.makeAsyncIterator()
        _ = await start.next()
        call.cancel()
        release.signal()
        if policyFirst {
            await #expect(throws: ItoError.networkPolicy(.hardUserBlocked)) { try await call.value }
        } else {
            await #expect(throws: CancellationError.self) { try await call.value }
        }
        _ = await retainedFailure(runner, fault: fault)
        #expect(try await runner.executeExport("probe_calls") == [.i32(0)])
    }

    @Test func ordinaryFailuresDoNotRetireTheInstance() async throws {
        let runner = try await Self.runner()
        let errors: [ItoError] = [
            .pluginFailed(function: "fixture", reason: nil, category: .other),
            .hostModuleError(domain: "net", message: "fixture"),
            .networkPolicy(.hardUserBlocked),
            .postcardDecodingError("fixture"),
            .postcardEncodingError("fixture"),
        ]
        for error in errors {
            await #expect(throws: error) { try await runner.healthNonCrash(error) }
            #expect(try await runner.healthProbe())
        }
    }

    @Test func anUncancelledCrashAlsoRetiresTheInstance() async throws {
        let runner = try await Self.runner()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        release.signal()
        await #expect(throws: ItoError.self) {
            try await runner.gatedHealthFault(.trap, faultFirst: true,
                entered: entered.continuation, release: release)
        }
        _ = await retainedFailure(runner, fault: .trap)
    }

    @Test func reloadRejectsAQueuedFailedGenerationBeforeCheckingItsHealth() async throws {
        let runner = try await Self.runner()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        release.signal()
        await #expect(throws: ItoError.self) {
            try await runner.gatedHealthFault(.trap, faultFirst: true,
                entered: entered.continuation, release: release)
        }
        let queue = await runner.executionQueue
        queue.suspend()
        let enqueued = AsyncStream<Void>.makeStream()
        let stale = Task { try await runner.healthProbe(enqueued: enqueued.continuation) }
        var enqueue = enqueued.stream.makeAsyncIterator()
        _ = await enqueue.next()
        await runner.healthEnqueueBarrier()
        do { try await runner.loadPlugin(fromBytes: Self.wasm()) }
        catch { queue.resume(); throw error }
        queue.resume()
        await #expect(throws: ItoError.pluginReloaded) { try await stale.value }
        #expect(try await runner.healthProbe())
    }
}

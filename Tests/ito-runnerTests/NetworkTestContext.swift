import Foundation
@testable import ito_runner

extension NetworkOperationContext {
    /// Explicit authority for tests unrelated to network policy. A fresh operation every call.
    static var test: Self {
        Self(purpose: .foregroundReading, sourceID: "test-source", authorizationScope: UUID(),
             operationID: UUID(), policyRevision: 0, generation: UUID())
    }
}

import Foundation

/// Host authority for one export. Never decoded from guest memory or request headers.
/// The host resolves source/account identity, evaluates policy before scheduling, and re-evaluates
/// each transport admission, retry, redirect and challenge using this same immutable value.
///
/// The host expires grants on batch completion/cancellation, relaunch, source/account changes,
/// connection class transitions and policy changes. Hard restrictions always win. The bridge
/// only governs explicit guest host-module calls: image, player, session and webview resource
/// traffic outside these modules needs independent host admission and best-effort cancellation.
/// It cannot guarantee zero bytes after a path transition.
///
/// Throw `HostNetworkPolicyOutcome` (or `ItoError.networkPolicy`) for authoritative admission
/// refusal. Of a refusal and a cancellation, whichever happened first decides the outer result;
/// either beats the guest's own failure or success, even if the guest caught the failed response.
/// Later guest calls short-circuit after refusal. No host authority is carried in the guest ABI.
///
/// Hosts must not log this value: it carries the source id and a grant reference.
public struct NetworkOperationContext: Sendable, Equatable {
    /// Why the host runs the export. Hosts decide purposes; a plugin can never raise its own.
    public enum Purpose: Sendable, Equatable {
        case foregroundReading, seriesMetadata, manualCatalogRefresh, prefetch
        case manualBulkDownload, automaticBulkDownload, trackerWrite, sourceSetup
        /// A background refresh of the library the user did not just ask for.
        case automaticLibraryUpdate
        /// Interactive search or browsing the user is looking at.
        case interactiveSearch
        /// Cover and thumbnail images.
        case coverImage
    }

    public let purpose: Purpose
    public let sourceID: String
    /// Opaque, ephemeral identity, not credentials. Replace on account/authorization changes.
    public let authorizationScope: UUID
    public let operationID: UUID
    public let batchID: UUID?
    public let policyRevision: UInt64
    /// Not read by the runner. Hosts should give every call a unique value so their own
    /// transports can tell calls apart.
    public let generation: UUID
    /// An opaque host capability reference, not a guest string. The host must validate its scope
    /// and lifetime on every admission; possession alone never overrides hard restrictions.
    public let scopedGrant: UUID?

    public init(purpose: Purpose, sourceID: String, authorizationScope: UUID,
                operationID: UUID, batchID: UUID? = nil, policyRevision: UInt64,
                generation: UUID, scopedGrant: UUID? = nil) {
        self.purpose = purpose
        self.sourceID = sourceID
        self.authorizationScope = authorizationScope
        self.operationID = operationID
        self.batchID = batchID
        self.policyRevision = policyRevision
        self.generation = generation
        self.scopedGrant = scopedGrant
    }
}

/// Trusted host admission failures. Modules throw these directly or wrapped in
/// `ItoError.networkPolicy`. The first outcome wins for the export even if the guest ignores it.
/// These are not HTTP errors or source retry failures. Cancellation uses `CancellationError`.
public enum HostNetworkPolicyOutcome: Error, Sendable, Equatable {
    public enum DeferralReason: Sendable, Equatable {
        case unknownPath, expensivePath, constrainedPath, offline, policyChanged
    }
    case deferred(DeferralReason)
    case foregroundPermissionRequired
    case hardUserBlocked
    case sourceAuthorizationFailure
}

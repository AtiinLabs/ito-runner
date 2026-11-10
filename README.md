# ito-runner

Swift package that runs [Ito](https://github.com/AtiinLabs/Ito) plugins. A plugin is an `.ito` bundle: a WebAssembly module written with [ito-rs](https://github.com/AtiinLabs/ito-rs), plus a manifest and icon. ito-runner executes it on [WasmKit](https://github.com/AtiinLabs/WasmKit), supplies the host modules it imports (network, HTML parsing, JavaScript, settings, web view), and exposes the plugin's manga, anime, and novel functions as Swift async methods. Calls cross the WebAssembly boundary as Postcard-encoded values.

## Requirements

- Swift 6.2
- iOS 15 or macOS 14

## Installation

Add the package by URL. It has no tagged releases, so pin a commit:

```swift
.package(url: "https://github.com/AtiinLabs/ito-runner.git", revision: "<commit>")
```

## Usage

```swift
import Foundation
import ito_runner

let runner = ItoRunner()
await runner.setNetModule(DefaultNetModule())
await runner.setHtmlModule(DefaultHtmlModule())
await runner.setStdModule(DefaultStdModule())

let manifest = try await runner.loadBundle(from: pluginURL)
let context = NetworkOperationContext(
    purpose: .interactiveSearch, sourceID: sourceID, authorizationScope: accountScope,
    operationID: UUID(), policyRevision: policyRevision, generation: UUID())
let results = try await runner.search(query: "frieren", page: 1, kind: .manga, context: context)
```

The default modules cover tests and simple hosts; Ito provides its own implementations of the host module protocols in `HostModules.swift`. `DefaultNetModule` ignores the context it is given, so it enforces nothing.

### Host-owned operation context

Every export takes a `NetworkOperationContext` the host builds: why the call runs (`purpose`), the
source, an opaque account scope, operation and batch identifiers, the policy revision and an
optional scoped grant. It never comes from the plugin, and it needs no ABI change: it is bound to
one serialized call, not stored on the runner. `NetModule.fetch(request:context:)`,
`WebviewModule.loadUrl(request:context:)` and `WebviewModule.executeJs(script:context:)` receive
the same immutable value, so a nested request, retry or challenge never has more authority than
the call that caused it. The same export can run as reading, prefetch or download under
different contexts. `generation` is not read by the runner; give every call a unique value.
The context carries the source id and a grant reference, so hosts must not log it.

A host module refuses a request by throwing `HostNetworkPolicyOutcome` (deferred, foreground
permission required, hard user block, source authorization failure) or
`ItoError.networkPolicy`. The plugin only sees a 500 response with a fixed text and the
`X-Ito-Transport-Error` header (or the no-result value for web view calls), and later requests of
that call are refused without reaching the module. A plugin that catches the failure and returns
an empty catalog still makes the outer call throw `ItoError.networkPolicy`, so a host never
stores an empty result or counts a retry for it. A real server 500, a transport failure and a
policy outcome stay distinct. Guest-visible texts are fixed English constants chosen from an
allowlist of `URLError` codes; host error descriptions are never copied to the plugin.

Of a policy refusal and a cancellation, whichever happened first decides the outer result
(`ItoError.networkPolicy` or `CancellationError`). Either beats the plugin's own failure or
success. A policy outcome also beats a trap. The runner does not report whether the plugin also
trapped; a host that discards runners after a crash should also discard them after `networkPolicy`.
Policy outcomes and cancellation
are never cached as capabilities.

Loading a plugin while an export runs throws `ItoError.reloadDuringActiveExport`: use a fresh
runner for overlapping work. A call queued before a successful reload throws
`ItoError.pluginReloaded` without running; it is not a cancellation. The runner governs only the
plugin's host-module calls. Image loading, players, sessions and web view resource traffic outside
these modules need the host's own admission, and in-flight work can only be cancelled best effort.

### Kinds

A plugin serves one or more `MediaKind`s (manga, anime, novel): `supportedKinds` after
loading, or `PluginInfo.supportedKinds` from its manifest. Catalog calls are kind-neutral:
`getListing(_:page:context:)`, `search(query:page:kind:filterValues:context:)` (nil searches every kind the plugin serves; a kind
it doesn't serve finds nothing without calling it), `getMediaUpdate(_:needsDetails:needsUnits:context:)`,
`getChapterPages(entry:chapter:context:)`, `getEpisodeVideos(anime:episode:context:)`. Entries are `MediaEntry` values; an update returns the same kind.

Each chapter's `ContentKind` says how it is read: `images` in a page reader, `text` in a
text reader that shows image pages inline. Chapters stored before kinds existed have no kind;
`MediaEntry.contentKind(of:)` reads them as their entry's kind says (manga as images, novels as
text). The runner runs ABI 3 plugins only (`ItoRunner.supportedABIVersions`); a plugin with another
ABI, or without `ito_error_version` 2 or later, is refused before anything of it is instantiated.

### Native image requests

`getImageRequest(_:context:)` optionally resolves a plugin-owned image locator into a
`PluginImageRequest` (URL and headers), without downloading image bytes. Fetch the
result outside the runner's serialized execution lane.

Before fetching, read the plugin's independently configured `getImageOrigins()`
and require the destination's scheme, host, and effective port to match an allowed
origin. Reject userinfo, non-HTTP(S) destinations, and cross-origin redirects;
do not attach shared cookies or log the URL/headers.

Missing or unsupported exports return `nil`, allowing the `handleImage(_:context:)`
path for plugins that don't resolve requests natively or for image transforms. A thrown error is an explicit refusal:
do not fall back to another fetch path. Keep request headers transient rather than
persisting them with the logical image locator.

### Completion notifications

`markCompleted(kind:mediaKey:unitKey:context:)` calls the optional completion export with
the plugin's opaque keys. It returns `true` only for an acknowledgement;
absent or unsupported/unhandled exports return `false`, while refusals and traps throw.
Malformed signatures and acknowledgement values also throw.

Commit local progress before invoking these calls. Durable delivery and idempotent retries
belong to the host; never infer opaque unit keys from numbered progress, or silently replay
queued writes against changed source/account settings. Both argument buffers are freed on
success, failure, and traps; the scalar acknowledgement allocates no response buffer.

### Settings diagnostics

`getSettingsActions(context:)` discovers optional diagnostic buttons,
`runSettingsAction(_:context:)` runs an explicitly selected action, and `validateSettings(context:)` returns advisory issues
keyed by setting ID (empty key for a form-level issue). Missing or Unsupported exports
return `nil`; successful empty arrays or strings remain empty, and other typed failures
throw. The existing settings schema is unchanged.

Run diagnostics against a temporary settings snapshot, including unsaved secret drafts
when appropriate. Never persist action writes or log setting values. Actions must be
non-destructive and must not require interactive login. Validation is local-only, without
network access or writes, and must not block saving incomplete settings.

### Rich settings and search controls

`getSettingsSurface(context:)` prefers a validated `SettingsForm` without calling the legacy
`get_settings` export. Missing or Unsupported forms fall back to `.legacy`; a failed
form carries `formFailure` alongside the legacy schema. Traps and memory failures
propagate. For `.form`, do not inject declared defaults into the host settings store:
unset keys must remain unset. Keep legacy default injection for `.legacy`.

Controls share `ControlKind`, `OptionSource`, `ControlValue`, and
`ControlValueCodec`. Store canonical strings for plain controls, retain invalid stored
values until a user edits or resets them, and keep secrets exclusively in credential
storage. `effectiveValue(stored:)` and visibility helpers apply defaults without
rewriting storage. Render unknown kinds as unavailable; never write values for them.

```swift
let capabilities = try await runner.getSearchCapabilities(kind: .manga, context: context)
let results = try await runner.search(
    query: "", page: 1, kind: .manga,
    filterValues: ["adult": .toggle(false), "genres": .multiSelect(["fantasy"])], context: context)
let options = try await runner.getOptionPage(
    OptionRequest(catalog: "genres", query: .search(text: "", offset: 0), limit: 50), context: context)
let suggestions = try await runner.getSearchSuggestions(query: "fri", kind: .manga, context: context)
```

Capabilities are cached per kind (including absence and non-crash failures, but never host policy
outcomes or cancellation) until a plugin is loaded again. Every search sends one canonical string item per known control,
in declaration order, applying defaults to invalid or hidden values. Searches without
capabilities send the unchanged empty filter list. The `filterValues` parameter replaces
the old low-level `filters` parameter; every call also supplies explicit host context.
Keep search choices in memory, never in the settings store.

Catalog requests support offset paging and batches of up to 100 selected values for label
resolution. On revision changes restart paging; failed label resolution must not remove
selections. Suggestions are called only when the capability flag is set. All new calls
use the serialized execution lane and preserve cancellation.

New optional exports require exact signatures. Response byte budgets are checked
before copying WASM memory; payloads and requests are validated against the rich-controls
v1 contract. `ItoError.controlContractViolation` exposes only a rule code and, optionally,
a validated identifier. Do not log values, queries, labels, catalog contents, or secrets.
The `FilterValue` variants are unchanged.

### Runner lifetime

A bridge holds no reference to its runner. Dropping the runner releases its ownership of the
bridge and attached host modules; externally retained bridges/modules keep their own lifetimes.
Standalone import callbacks retain their codecs and use the WASM caller's memory, and work
without any runner.

### Error-report protocol versions

The runner reads `ito_error_version() -> i32` from the module bytes before loading, without
calling it. It must be a function the module defines whose body is a single `i32.const` of 2 or
more; an absent, imported, computed, mistyped or non-function export rejects the load.
Failures are then reported with an explicit category, and only the `unsupported` category means
an unsupported operation. Other failures remain refusals even if their message says
“Unsupported operation.” A plugin's `contractViolation` report is read by its fixed rule code
only (`ItoError.catalogContractViolation`); its text is never kept or shown.

## License

[PolyForm Shield 1.0.0](LICENSE)

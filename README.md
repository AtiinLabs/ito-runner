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
import ito_runner

let runner = ItoRunner()
await runner.setNetModule(DefaultNetModule())
await runner.setHtmlModule(DefaultHtmlModule())
await runner.setStdModule(DefaultStdModule())

let manifest = try await runner.loadBundle(from: pluginURL)
let results = try await runner.search(query: "frieren", page: 1, kind: .manga)
```

The default modules cover tests and simple hosts; Ito provides its own implementations of the host module protocols in `HostModules.swift`.

### Kinds

A plugin serves one or more `MediaKind`s (manga, anime, novel): `supportedKinds` after
loading, or `PluginInfo.supportedKinds` from its manifest. Catalog calls are kind-neutral:
`getListing`, `search(query:page:kind:)` (nil searches every kind the plugin serves; a kind
it doesn't serve finds nothing without calling it), `getMediaUpdate`, `getChapterPages`,
`getEpisodeVideos`. Entries are `MediaEntry` values; an update returns the same kind.

Each chapter's `ContentKind` says how it is read: `images` in a page reader, `text` in a
text reader that shows image pages inline. Chapters from plugins built for ABI 1, or stored
before kinds existed, have no kind; `MediaEntry.contentKind(of:)` reads them as their entry's
kind says (manga as images, novels as text). The runner runs ABI 1 and ABI 2 plugins.

### Native image requests

`getImageRequest(_:)` optionally resolves a plugin-owned image locator into a
`PluginImageRequest` (URL and headers), without downloading image bytes. Fetch the
result outside the runner's serialized execution lane.

Before fetching, read the plugin's independently configured `getImageOrigins()`
and require the destination's scheme, host, and effective port to match an allowed
origin. Reject userinfo, non-HTTP(S) destinations, and cross-origin redirects;
do not attach shared cookies or log the URL/headers.

Missing or unsupported exports return `nil`, allowing the legacy `handleImage(_:)`
path for older plugins or image transforms. A thrown error is an explicit refusal:
do not fall back to another fetch path. Keep request headers transient rather than
persisting them with the logical image locator.

### Completion notifications

`markCompleted(kind:mediaKey:unitKey:)` calls the optional completion export with
the plugin's opaque keys. It returns `true` only for an acknowledgement;
absent or unsupported/unhandled exports return `false`, while refusals and traps throw.
Malformed signatures and acknowledgement values also throw.

Commit local progress before invoking these calls. Durable delivery and idempotent retries
belong to the host; never infer opaque unit keys from numbered progress, or silently replay
queued writes against changed source/account settings. Both argument buffers are freed on
success, failure, and traps; the scalar acknowledgement allocates no response buffer.

### Settings diagnostics

`getSettingsActions()` discovers optional diagnostic buttons, `runSettingsAction(_:)`
runs an explicitly selected action, and `validateSettings()` returns advisory issues
keyed by setting ID (empty key for a form-level issue). Missing or Unsupported exports
return `nil`; successful empty arrays or strings remain empty, and other typed failures
throw. The existing settings schema and ABI 1 are unchanged.

Run diagnostics against a temporary settings snapshot, including unsaved secret drafts
when appropriate. Never persist action writes or log setting values. Actions must be
non-destructive and must not require interactive login. Validation is local-only, without
network access or writes, and must not block saving incomplete settings.

### Rich settings and search controls

`getSettingsSurface()` prefers a validated `SettingsForm` without calling the legacy
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
let capabilities = try await runner.getSearchCapabilities(kind: .manga)
let results = try await runner.search(
    query: "", page: 1, kind: .manga,
    filterValues: ["adult": .toggle(false), "genres": .multiSelect(["fantasy"])])
let options = try await runner.getOptionPage(
    OptionRequest(catalog: "genres", query: .search(text: "", offset: 0), limit: 50))
let suggestions = try await runner.getSearchSuggestions(query: "fri", kind: .manga)
```

Capabilities are cached per kind (including absence and non-crash failures) until a
plugin is loaded again. Every search sends one canonical string item per known control,
in declaration order, applying defaults to invalid or hidden values. Searches without
capabilities send the unchanged empty filter list. The `filterValues` parameter replaces
the old low-level `filters` parameter; callers omitting filters remain source-compatible.
Keep search choices in memory, never in the settings store.

Catalog requests support offset paging and batches of up to 100 selected values for label
resolution. On revision changes restart paging; failed label resolution must not remove
selections. Suggestions are called only when the capability flag is set. All new calls
use the serialized execution lane and preserve cancellation.

New optional exports require ABI 2 and exact signatures. Response byte budgets are checked
before copying WASM memory; payloads and requests are validated against the rich-controls
v1 contract. `ItoError.controlContractViolation` exposes only a rule code and, optionally,
a validated identifier. Do not log values, queries, labels, catalog contents, or secrets.
The legacy wire layouts, ABI version, and `FilterValue` variants are unchanged.

### Runner lifetime

The bridge keeps a weak runner reference, breaking the loaded-runner retain cycle. Dropping
the runner releases its ownership of the bridge and attached host modules; externally retained
bridges/modules keep their own lifetimes. Standalone import callbacks retain their codecs and
use the WASM caller's memory. Keep the runner alive when calling `WasmBridge.readRequest` or
`writeResponse`; these utilities throw if their runner has gone away.

### Error-report protocol versions

The runner reads optional `ito_error_version() -> i32` once when loading a plugin.
Absent means version 1; a present malformed or trapping export rejects the load.
Version 2 reports unsupported operations with the explicit `unsupported` category.
Other failures remain refusals even if their message says “Unsupported operation.”

For version 1 only, `other` plus that exact legacy text still means unsupported:
older SDKs used it for both cases, so that historical ambiguity cannot be recovered.
Typed authentication or server errors never become unsupported based on their text.

## License

[PolyForm Shield 1.0.0](LICENSE)

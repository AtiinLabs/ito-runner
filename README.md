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
let results = try await runner.getSearchMangaList(query: "frieren", page: 1, filters: nil)
```

The default modules cover tests and simple hosts; Ito provides its own implementations of the host module protocols in `HostModules.swift`.

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

`markChapterRead(mediaKey:chapterKey:)` (manga or novel) and
`markEpisodeWatched(mediaKey:episodeKey:)` call optional completion exports with
the plugin's opaque keys. They return `true` only for an acknowledgement;
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

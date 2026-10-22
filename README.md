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

## License

[PolyForm Shield 1.0.0](LICENSE)

import Foundation
import ZIPFoundation

/// The parts of a packaged `.ito` archive the runner reads. Entries are found by name without
/// extracting anything, and each read stops once it exceeds its byte limit, so a hostile archive
/// can't make the host inflate more than the limits allow.
///
/// Packagers write `manifest.json`, `main.wasm` and `icon.png` at the archive root. Bundles from
/// before those names were fixed, or zipped inside a folder, have the module and manifest under
/// other names: when a fixed root name is absent, the last `*.json` / `*.wasm` entry at any depth
/// and the last entry ending `icon.png` / `icon.jpg` stand in, as they always have. Resource-fork
/// folders (`__MACOSX/`) are skipped.
struct PluginBundle {
    static let manifestName = "manifest.json"
    static let iconName = "icon.png"
    static let wasmName = "main.wasm"
    static let manifestByteLimit = 1 << 20
    static let wasmByteLimit = 32 << 20
    static let iconByteLimit = 4 << 20

    private let archive: Archive
    private let manifestEntry: Entry?
    private let wasmEntry: Entry?
    private let iconEntry: Entry?

    /// Opens the archive at `url`; throws when it can't be read as one.
    init(at url: URL) throws {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ItoError.wasmTrap("Failed to read .ito archive at \(url)")
        }
        self.archive = archive

        var manifest = Candidates()
        var wasm = Candidates()
        var icon = Candidates()
        for entry in archive where entry.type == .file {
            let path = entry.path
            // Archives made by Finder carry resource forks of every file under this folder.
            guard !path.hasPrefix("__MACOSX/") && !path.contains("/__MACOSX/") else { continue }
            let lowercased = path.lowercased()
            if path == Self.manifestName {
                manifest.fixed = entry
            } else if path.hasSuffix(".json") {
                manifest.legacy = entry
            }
            if path == Self.wasmName {
                wasm.fixed = entry
            } else if path.hasSuffix(".wasm") {
                wasm.legacy = entry
            }
            if lowercased == Self.iconName {
                icon.fixed = entry
            } else if lowercased.hasSuffix("icon.png") || lowercased.hasSuffix("icon.jpg") {
                icon.legacy = entry
            }
        }
        manifestEntry = manifest.chosen
        wasmEntry = wasm.chosen
        iconEntry = icon.chosen
    }

    /// The manifest, or nil when the archive has none. Throws when it is larger than `limit` or
    /// can't be read or decoded.
    func manifest(limit: Int = Self.manifestByteLimit) throws -> PluginManifest? {
        guard let manifestEntry else { return nil }
        let bytes = try contents(of: manifestEntry, limit: limit)
        return try JSONDecoder().decode(PluginManifest.self, from: Data(bytes))
    }

    /// The module's bytes. Throws when the archive has none, or it is larger than `limit` or can't
    /// be read.
    func wasm(limit: Int = Self.wasmByteLimit) throws -> [UInt8] {
        guard let wasmEntry else { throw ItoError.wasmTrap("Archive did not contain a .wasm file.") }
        return try contents(of: wasmEntry, limit: limit)
    }

    /// The icon, or nil when the archive has none or it can't be read.
    func icon() -> Data? {
        guard let iconEntry, let bytes = try? contents(of: iconEntry, limit: Self.iconByteLimit) else { return nil }
        return Data(bytes)
    }

    private struct Candidates {
        var fixed: Entry?
        var legacy: Entry?
        var chosen: Entry? { fixed ?? legacy }
    }

    private func contents(of entry: Entry, limit: Int) throws -> [UInt8] {
        let tooLarge = ItoError.wasmTrap("\(entry.path) in the .ito archive is larger than \(limit) bytes.")
        guard entry.uncompressedSize <= UInt64(limit) else { throw tooLarge }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(entry.uncompressedSize))
        do {
            let checksum = try archive.extract(entry) { chunk in
                // The declared size is the archive's claim; the limit holds whatever the stream yields.
                guard bytes.count + chunk.count <= limit else { throw tooLarge }
                bytes.append(contentsOf: chunk)
            }
            guard checksum == entry.checksum else {
                throw ItoError.wasmTrap("\(entry.path) in the .ito archive fails its checksum.")
            }
        } catch let error as ItoError {
            throw error
        } catch {
            throw ItoError.wasmTrap("Failed to read \(entry.path) from the .ito archive: \(error)")
        }
        return bytes
    }
}

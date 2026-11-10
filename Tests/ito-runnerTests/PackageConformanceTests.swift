import Foundation
import Testing
@testable import ito_runner

/// Every plugin package a release train built is an ABI 3 package this runner can run.
///
/// Set `ITO_PACKAGES_DIR` to a directory of `.ito` files (searched recursively) to run it; without
/// the variable there is nothing to check and the suite is skipped.
private enum PackageDirectory {
    static let url: URL? = ProcessInfo.processInfo.environment["ITO_PACKAGES_DIR"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    static var packages: [URL] {
        guard let url, let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "ito" }
            .sorted { $0.path < $1.path }
    }
}

@Suite("Plugin package conformance", .enabled(if: PackageDirectory.url != nil, "ITO_PACKAGES_DIR is not set"))
struct PackageConformanceTests {
    @Test func theDirectoryHasPackagesToCheck() throws {
        let directory = try #require(PackageDirectory.url)
        #expect(!PackageDirectory.packages.isEmpty, "no .ito package under \(directory.path)")
    }

    @Test(arguments: PackageDirectory.packages)
    func aPackageIsABI3AndItsKindsAndImportsAreOnesThisRunnerKnows(_ package: URL) async throws {
        let name = package.lastPathComponent
        let (manifest, binary) = try ItoRunner.inspectBundle(at: package)
        let interface = try #require(binary, "\(name): the module can't be read statically")

        #expect(interface.abiVersion == 3, "\(name): built for ABI \(interface.abiVersion)")
        #expect(!interface.hasStartSection, "\(name): has a start section")
        #expect(interface.errorProtocolVersion >= ItoRunner.minimumErrorProtocolVersion, "\(name): reports failures in an old format")
        let kinds = try #require(interface.kinds, "\(name): ito_supported_kinds names no kind this runner knows")
        #expect(Set(kinds) == Set(manifest.info.supportedKinds), "\(name): the manifest says \(manifest.info.supportedKinds), the module \(kinds)")
        #expect(ItoRunner.unsupportedImports(interface.imports).isEmpty,
                "\(name): imports \(ItoRunner.unsupportedImports(interface.imports))")
        if let declared = manifest.info.abi {
            #expect(declared == interface.abiVersion, "\(name): the manifest says ABI \(declared)")
        }
        #expect(ItoRunner.compatibility(of: interface) == .compatible, "\(name)")

        // And it loads: its imports and exports line up with this runner's.
        let runner = ItoRunner()
        _ = try await runner.loadBundle(from: package)
        #expect(await runner.abiVersion == 3)
        #expect(Set(await runner.supportedKinds) == Set(kinds))
    }
}

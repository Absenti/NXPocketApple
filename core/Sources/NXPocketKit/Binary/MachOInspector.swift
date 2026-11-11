import Foundation

/// The rules a framework received from the Mac app must satisfy before it is signed and run with the app's own
/// privileges. Nothing here trusts the sender: the package is checked as if it were hostile.
public enum MachOInspector {
    public struct Policy: Sendable {
        public var maximumMinimumOS: OSVersion
        /// Absolute prefixes a dynamic dependency may point at.
        public var systemPrefixes: [String]
        /// Relative prefixes a dynamic dependency may point at, resolved inside the app or the framework.
        public var relativePrefixes: [String]

        public init(maximumMinimumOS: OSVersion = .current,
                    systemPrefixes: [String] = ["/usr/lib/", "/System/Library/", "/System/iOSSupport/"],
                    relativePrefixes: [String] = ["@rpath/", "@loader_path/", "@executable_path/"]) {
            self.maximumMinimumOS = maximumMinimumOS
            self.systemPrefixes = systemPrefixes
            self.relativePrefixes = relativePrefixes
        }

        public static let `default` = Policy()
    }

    public struct Report: Sendable {
        public var executable: URL
        public var header: MachOFile.Header
        public var architecture: String
        public var minimumOS: OSVersion?
        public var dependencies: [MachOFile.Dependency]
        public var warnings: [String]
    }

    /// `frameworkRoot` is the `.framework` folder; `allowedRoots` also lists the app's own Frameworks folder.
    @discardableResult
    public static func inspectExecutable(at executable: URL, frameworkRoot: URL,
                                         allowedRoots: [URL] = [], policy: Policy = .default) throws -> Report {
        let image = try MachOFile.parse(contentsOf: executable)
        let path = executable.path

        guard image.header.isARM64 else {
            throw NXPocketError(.wrongArchitecture,
                                String(format: "expected arm64, found cpu type %#x", UInt32(bitPattern: image.header.cpuType)),
                                path: path)
        }
        guard image.header.isDylib else {
            throw NXPocketError(.wrongMachOType, "expected a dylib (MH_DYLIB), found file type \(image.header.fileType)", path: path)
        }
        guard let build = image.buildVersion else {
            throw NXPocketError(.minimumOSNewer, "the framework states no LC_BUILD_VERSION, so its iOS deployment target is unknown", path: path)
        }
        guard build.platform == MachOFile.BuildVersion.platformIOS
                || build.platform == MachOFile.BuildVersion.platformIOSTargetEnvironmentSimulator else {
            throw NXPocketError(.wrongArchitecture, "the framework was not built for iOS (platform \(build.platform))", path: path)
        }
        guard let minimum = image.minimumOS else {
            throw NXPocketError(.minimumOSNewer, "the framework states no deployment target", path: path)
        }
        guard minimum <= policy.maximumMinimumOS else {
            throw NXPocketError(.minimumOSNewer,
                                "the framework needs iOS \(minimum) and this device runs \(policy.maximumMinimumOS)", path: path)
        }

        let roots = [frameworkRoot] + allowedRoots
        var warnings: [String] = []
        for dependency in image.dependencies where dependency.kind != .identifier {
            try check(dependency, roots: roots, policy: policy, executable: executable, warnings: &warnings)
        }
        for rpath in image.rpaths where !isAllowedRelative(rpath, policy: policy) {
            throw NXPocketError(.forbiddenDependency, "the framework adds rpath \"\(rpath)\"", path: path)
        }
        if !image.rpaths.isEmpty {
            warnings.append("declares rpaths: \(image.rpaths.joined(separator: ", "))")
        }

        return Report(executable: executable, header: image.header,
                      architecture: "arm64", minimumOS: minimum,
                      dependencies: image.dependencies, warnings: warnings)
    }

    private static func check(_ dependency: MachOFile.Dependency, roots: [URL], policy: Policy,
                              executable: URL, warnings: inout [String]) throws {
        let name = dependency.name
        let path = executable.path
        if name.hasPrefix("/") {
            guard isAllowedAbsolute(name, policy: policy) else {
                throw NXPocketError(.forbiddenDependency, "the framework links \"\(name)\", which is outside the system libraries", path: path)
            }
            return
        }
        guard let relative = remainder(of: name, policy: policy) else {
            throw NXPocketError(.forbiddenDependency, "the framework links \"\(name)\", which is neither absolute nor a known relative form", path: path)
        }
        guard SafePath.isSafeRelative(relative) else {
            throw NXPocketError(.unsafePath, "the framework links \"\(name)\", whose path escapes the package", path: path)
        }
        for root in roots {
            let candidate = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            guard SafePath.contains(candidate, in: root) else {
                throw NXPocketError(.forbiddenDependency, "the framework links \"\(name)\", which resolves outside the framework", path: path)
            }
            return
        }
        warnings.append("unresolved dependency: \(name)")
    }

    static func isAllowedAbsolute(_ name: String, policy: Policy) -> Bool {
        policy.systemPrefixes.contains { name.hasPrefix($0) }
    }

    static func isAllowedRelative(_ name: String, policy: Policy) -> Bool {
        remainder(of: name, policy: policy) != nil
    }

    static func remainder(of name: String, policy: Policy) -> String? {
        for prefix in policy.relativePrefixes where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }
}

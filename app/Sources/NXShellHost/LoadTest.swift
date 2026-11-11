import Foundation

/// What "Test loading" measured on a real game: everything `play()` does before it hands over to the engine, and
/// nothing after. The game's framework is signed if it needs to be, loaded from Documents, and checked for the
/// manifest's marker and for the sections the engine's loader maps for each module. Those are located, never run:
/// running them would be running the game, which is the engine's job.
///
/// It exists to answer, before the engine port, the questions only a real game asks: how long a framework of that
/// size takes to sign on the phone, whether iOS loads it from Documents, and what it costs in memory.
public struct LoadTestReport: Equatable, Sendable {
    /// Seconds spent signing, or nil when the framework already carried a valid signature.
    public var signingSeconds: Double?
    public var executableBytes: Int64
    public var loadSeconds: Double
    public var markerFound: Bool
    public var marker: String
    /// The embedded modules the manifest names, with the sections the loader reads for each (`FrameworkLoader`).
    public var modules: [Module]
    public var availableBefore: Int64
    public var availableAfter: Int64

    /// One module the engine maps, or the packed NRO pieces when the game has any.
    public struct Module: Equatable, Sendable {
        public var name: String
        public var sections: [Section]

        public init(name: String, sections: [Section]) {
            self.name = name
            self.sections = sections
        }

        public var isUsable: Bool { !sections.isEmpty && sections.allSatisfy(\.isUsable) }
    }

    /// A section as the loaded image has it: nil size when it is missing.
    public struct Section: Equatable, Sendable {
        public var name: String
        public var size: Int?
        public var aligned: Bool

        public init(name: String, size: Int?, aligned: Bool) {
            self.name = name
            self.size = size
            self.aligned = aligned
        }

        public var isUsable: Bool { size != nil && aligned }
    }

    public init(signingSeconds: Double?, executableBytes: Int64, loadSeconds: Double, markerFound: Bool,
                marker: String, modules: [Module], availableBefore: Int64, availableAfter: Int64) {
        self.signingSeconds = signingSeconds
        self.executableBytes = executableBytes
        self.loadSeconds = loadSeconds
        self.markerFound = markerFound
        self.marker = marker
        self.modules = modules
        self.availableBefore = availableBefore
        self.availableAfter = availableAfter
    }

    /// Everything the engine will need is there: the image is this game's, and every module's sections are where
    /// the loader expects them.
    public var passed: Bool { markerFound && !modules.isEmpty && modules.allSatisfy(\.isUsable) }

    /// One line per measurement, in the import log's language (English, like the rest of the log).
    public var lines: [String] {
        var lines: [String] = []
        let size = ByteCountFormatter.string(fromByteCount: executableBytes, countStyle: .file)
        if let signingSeconds {
            let rate = signingSeconds > 0 ? Double(executableBytes) / 1_048_576 / signingSeconds : 0
            lines.append(String(format: "signed: %.1f s for %@ (%.1f MB/s)", signingSeconds, size, rate))
        } else {
            lines.append("signed: already, with the current certificate (\(size))")
        }
        lines.append(String(format: "loaded from Documents in %.0f ms", loadSeconds * 1000))
        lines.append(markerFound ? "marker \(marker): found, this is the game's code"
                                 : "marker \(marker): MISSING, the loaded image is not this game's code")
        if modules.isEmpty { lines.append("modules: the manifest names none") }
        for module in modules {
            let parts = module.sections.map { section -> String in
                guard let bytes = section.size else { return "\(section.name) MISSING" }
                let text = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
                return "\(section.name) \(text)" + (section.aligned ? "" : " NOT 16K-aligned")
            }
            lines.append("module \(module.name): " + parts.joined(separator: ", ")
                         + (module.isUsable ? ", all 16K-aligned" : ""))
        }
        let before = ByteCountFormatter.string(fromByteCount: availableBefore, countStyle: .memory)
        let after = ByteCountFormatter.string(fromByteCount: availableAfter, countStyle: .memory)
        lines.append("memory available: \(before) before, \(after) after")
        lines.append(passed ? "RESULT: the game loads; the engine is all that is missing"
                            : "RESULT: the game loaded, but not as the engine needs it (see above)")
        return lines
    }
}

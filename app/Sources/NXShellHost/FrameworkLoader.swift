import Darwin
import Foundation
import MachO
import NXPocketKit

/// A framework the shell has loaded. iOS never unloads a dylib, so a loaded game stays loaded for the life of the
/// process: the shell runs one game per launch, which is why returning to the library restarts the app.
public struct LoadedFramework {
    public var handle: UnsafeMutableRawPointer
    public var imageBase: UnsafeRawPointer
    public var path: String
}

/// `dlopen` of a framework in `Documents`, plus the code-page remap the engine's loader does.
///
/// A copy of a signed framework does not load from outside the bundle unless the device signed it itself with the
/// app's own signature identifier; `docs/SIGNING.md` records the probe that established this.
public enum FrameworkLoader {
    /// What dyld said the last time it refused a game's code, for the error report.
    public static var lastDlerror: String?

    public static let codePageSegment = "__TEXT"
    public static let codePageSection = "__dmx0"
    public static let pageSize = 0x4000

    /// Loads `executable` and refuses an answer that is not the file we asked for: dyld would otherwise hand back a
    /// copy it already had, and the game's own code would never run.
    public static func load(executable: URL) throws -> LoadedFramework {
        let path = executable.path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "no reason given"
            lastDlerror = reason
            throw NXPocketError(.notSigned, "dlopen refused \(executable.lastPathComponent): \(reason)", path: path)
        }
        // The handle cannot be given to dladdr: dyld4 returns a pointer to its own record of the image, which lies in
        // no image, so dladdr always fails on it (the first real game failed exactly so, after dlopen had succeeded).
        // The image is looked up among the loaded ones instead, by the file it was loaded from.
        let images = loadedImages(named: executable.lastPathComponent)
        let wanted = executable.resolvingSymlinksInPath()
        guard let base = images.first(where: { $0.url == wanted })?.header else {
            let other = images.first.map { "the image it already had at \($0.url.path)" } ?? "no image of that name"
            throw NXPocketError(.engineFailed, "dyld answered with \(other), not the file we asked for", path: path)
        }
        return LoadedFramework(handle: handle, imageBase: base, path: path)
    }

    /// The images this process has loaded whose file is called `name`, with the path dyld loaded each from. Only
    /// those are resolved: the hundreds of system images in the shared cache have no file to resolve.
    static func loadedImages(named name: String) -> [(url: URL, header: UnsafeRawPointer)] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let cName = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { return nil }
            let url = URL(fileURLWithPath: String(cString: cName))
            guard url.lastPathComponent == name else { return nil }
            return (url.resolvingSymlinksInPath(), UnsafeRawPointer(header))
        }
    }

    /// Whether this process already has an image loaded from `executable`. dyld never unloads one, and hands it back
    /// for the same path even after the file was replaced, so a second load in the same process proves nothing about
    /// the file on disk (the probe's second run showed exactly that).
    public static func isLoaded(executable: URL) -> Bool {
        guard let handle = dlopen(executable.path, RTLD_NOLOAD | RTLD_LAZY) else { return false }
        dlclose(handle)
        return true
    }

    /// The sections the engine's loader maps for each module, read from a loaded image without running anything
    /// (engine `dm/host/loader.c`, `map_image`): `__TEXT,__dm<module>x0`, `__DM<module>W,__img` and
    /// `__TEXT,__dm<module>x1`, each 16K-aligned. A game with NROs has them packed in four shared sections instead
    /// (`nro_pieces`). The probe's single `__TEXT,__dmx0` is not what a real game holds: the first one had
    /// `__dmmainx0` and `__dmsdkx0`.
    public static func moduleSections(of framework: LoadedFramework, modules: [String],
                                      nroCount: Int) -> [LoadTestReport.Module] {
        var found = modules.map { name in
            LoadTestReport.Module(name: name, sections: [
                section(of: framework, "__TEXT", "__dm\(name)x0"),
                section(of: framework, "__DM\(name)W", "__img"),
                section(of: framework, "__TEXT", "__dm\(name)x1"),
            ])
        }
        if nroCount > 0 {
            found.append(LoadTestReport.Module(name: "NROs (\(nroCount))", sections: [
                section(of: framework, "__DATA", "__dm_nro_tab", aligned: false),
                section(of: framework, "__TEXT", "__dm_nro_x0"),
                section(of: framework, "__DM_NRO_W", "__img"),
                section(of: framework, "__TEXT", "__dm_nro_x1"),
            ]))
        }
        return found
    }

    /// One section of a loaded image. `aligned: false` is for a table, which the loader reads but never remaps.
    static func section(of framework: LoadedFramework, _ segment: String, _ name: String,
                        aligned needsAlignment: Bool = true) -> LoadTestReport.Section {
        let label = segment == "__TEXT" || segment == "__DATA" ? name : segment
        var size: UInt = 0
        guard let data = getsectiondata(framework.imageBase.assumingMemoryBound(to: mach_header_64.self),
                                        segment, name, &size), size > 0 else {
            return LoadTestReport.Section(name: label, size: nil, aligned: false)
        }
        let aligned = !needsAlignment || UInt(bitPattern: data) % UInt(pageSize) == 0
        return LoadTestReport.Section(name: label, size: Int(size), aligned: aligned)
    }

    /// The marker the manifest names, found in the very file that was loaded. Every game exports the same marker, so
    /// finding it proves only that some game's code answered; the image it lies in is what proves it is this one.
    public static func verify(_ framework: LoadedFramework, marker: String) throws {
        guard let symbol = dlsym(framework.handle, marker) else {
            throw NXPocketError(.packageDamaged, "the framework exports no \(marker): it is not this game's code",
                                path: framework.path)
        }
        var info = Dl_info()
        guard dladdr(symbol, &info) != 0, let file = info.dli_fname,
              URL(fileURLWithPath: String(cString: file)).resolvingSymlinksInPath()
                == URL(fileURLWithPath: framework.path).resolvingSymlinksInPath() else {
            throw NXPocketError(.packageDamaged, "\(marker) lies in another image than \(framework.path)", path: framework.path)
        }
    }

    /// Runs the 16K-aligned `__TEXT,__dmx0` page from a second mapping, so the module's code is executed from an
    /// address the loader chose rather than the one the file maps to.
    @discardableResult
    public static func runCodePage(of framework: LoadedFramework, section: String = codePageSection) throws -> Int32 {
        var size: UInt = 0
        guard let page = getsectiondata(framework.imageBase.assumingMemoryBound(to: mach_header_64.self),
                                       codePageSegment, section, &size), size > 0 else {
            throw NXPocketError(.engineMissing, "the image has no \(codePageSegment),\(section) section")
        }
        guard size >= UInt(pageSize), UInt(bitPattern: page) % UInt(pageSize) == 0 else {
            throw NXPocketError(.engineMissing, "\(codePageSegment),\(section) is not a 16K-aligned page")
        }
        var target: vm_address_t = 0
        guard vm_allocate(mach_task_self_, &target, vm_size_t(size), VM_FLAGS_ANYWHERE) == KERN_SUCCESS else {
            throw NXPocketError(.engineFailed, "vm_allocate failed")
        }
        var keep = false
        defer { if !keep { vm_deallocate(mach_task_self_, target, vm_size_t(size)) } }
        var address = target
        var current: vm_prot_t = 0
        var maximum: vm_prot_t = 0
        let result = vm_remap(mach_task_self_, &address, vm_size_t(size), 0,
                              VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self_,
                              vm_address_t(bitPattern: page), 0, &current, &maximum, VM_INHERIT_NONE)
        guard result == KERN_SUCCESS, address == target else {
            throw NXPocketError(.engineFailed, "vm_remap failed (\(result))")
        }
        guard current & (VM_PROT_READ | VM_PROT_EXECUTE) == (VM_PROT_READ | VM_PROT_EXECUTE),
              let entry = UnsafeRawPointer(bitPattern: UInt(target)) else {
            throw NXPocketError(.engineFailed, String(format: "the remapped page is not r-x (%#x)", Int(current)))
        }
        // The mapping stays: the code it runs may keep pointers into it.
        keep = true
        return unsafeBitCast(entry, to: int_fn.self)()
    }

    typealias int_fn = @convention(c) () -> Int32
}

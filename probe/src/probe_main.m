// NXPocket probe: can a sideloaded app load game code that is NOT inside its bundle?
// The question for a shell app that receives games without being reinstalled: a framework placed in
// Documents/, signed with the same team as the app, must dlopen, run, and give its __TEXT pages to
// vm_remap. An ad-hoc-only framework must be refused (otherwise a success proves nothing).
// Every step goes to Documents/probe-log.txt (synced line by line, so a crash keeps the last step) and to the screen.
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <mach-o/getsect.h>
#include <sys/utsname.h>
#include <mach-o/loader.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <unistd.h>
#include "zsign_shim.h"     // tools/zsign_shim.h, out of the xcframework the probe links against

static NSMutableString *g_log;
static NSString *g_logPath;

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [g_log appendFormat:@"%@\n", s];
    NSLog(@"%@", s);
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [h seekToEndOfFile];
    [h writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [h synchronizeFile];
    [h closeFile];
}

typedef int (*int_fn)(void);
typedef enum { R_PASS, R_FAIL, R_SKIP } result_t;
static const char *rname(result_t r) { return r == R_PASS ? "PASS" : r == R_FAIL ? "FAIL" : "SKIP"; }

// Run the code page in __TEXT,__dmx0 of the image at `base` from another address, as nxnative's loader does.
static BOOL run_blob(NSString *tag, const void *base) {
    unsigned long sz = 0;
    uint8_t *sec = getsectiondata((const struct mach_header_64 *)base, "__TEXT", "__dmx0", &sz);
    if (!sec) { L(@"[%@] no __TEXT,__dmx0 section", tag); return NO; }
    if (sz < 0x4000 || ((uintptr_t)sec & 0x3FFF)) { L(@"[%@] __dmx0 at %p size %#lx: not 16K aligned", tag, sec, sz); return NO; }
    vm_address_t to = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &to, sz, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { L(@"[%@] vm_allocate failed: %d", tag, kr); return NO; }
    vm_address_t a = to; vm_prot_t cur = 0, max = 0;
    kr = vm_remap(mach_task_self(), &a, sz, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                  (vm_address_t)sec, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS || a != to) { L(@"[%@] vm_remap failed: %d", tag, kr); return NO; }
    if ((cur & (VM_PROT_READ | VM_PROT_EXECUTE)) != (VM_PROT_READ | VM_PROT_EXECUTE)) {
        L(@"[%@] vm_remap gave protection %#x, not r-x", tag, cur); return NO;
    }
    L(@"[%@] __dmx0 %p remapped to %#lx (prot %#x), calling it", tag, sec, (unsigned long)to, cur);
    int r = ((int_fn)to)();
    L(@"[%@] remapped code returned %d (want 44)", tag, r);
    return r == 44;
}

// dlopen `path`, check the symbol really comes from that file (not another copy dyld already had), call it,
// then run its code page from a remapped address when `blob` is set.
static result_t try_load(NSString *tag, NSString *path, const char *sym, int want, BOOL blob) {
    L(@"[%@] dlopen %@", tag, path);
    // dyld never unloads an image, and hands back the one it has for a path even when the file has since been
    // replaced. A second run in the same process (after importing a certificate, say) would then "pass" a test with
    // an earlier test's image: the 2026-11-10 run showed 5A passing at the very address 5C had loaded. Ask first.
    void *already = dlopen(path.fileSystemRepresentation, RTLD_NOLOAD | RTLD_LAZY);
    if (already) {
        L(@"[%@] SKIP: an image is already loaded from this path, and dyld would hand it back, so this run says "
          "nothing about the file just written. Relaunch the app to run this test again.", tag);
        dlclose(already);
        return R_SKIP;
    }
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) { const char *e = dlerror(); L(@"[%@] dlopen refused: %s", tag, e ? e : "(no dlerror)"); return R_FAIL; }
    int_fn f = (int_fn)dlsym(h, sym);
    if (!f) { const char *e = dlerror(); L(@"[%@] dlsym %s failed: %s", tag, sym, e ? e : "?"); return R_FAIL; }
    Dl_info di = {0};
    if (!dladdr((const void *)f, &di) || !di.dli_fname) { L(@"[%@] dladdr found no image", tag); return R_FAIL; }
    char want_rp[PATH_MAX], got_rp[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, want_rp) || !realpath(di.dli_fname, got_rp) || strcmp(want_rp, got_rp)) {
        L(@"[%@] WRONG IMAGE: %s came from %s", tag, sym, di.dli_fname); return R_FAIL;
    }
    int r = f();
    L(@"[%@] %s() = %d (want %d), from %s", tag, sym, r, want, di.dli_fname);
    if (r != want) return R_FAIL;
    if (blob && !run_blob(tag, di.dli_fbase)) return R_FAIL;
    return R_PASS;
}

static NSString *sha256_of(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!d) return @"unreadable";
    uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 8; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

// The printable text that follows `key` in a binary blob (a certificate's subject name in the CMS signature).
static NSString *find_text(const uint8_t *b, size_t n, const char *key) {
    size_t k = strlen(key);
    for (size_t i = 0; i + k <= n; i++) if (!memcmp(b + i, key, k)) {
        size_t j = i; while (j < n && j - i < 80 && b[j] >= 0x20 && b[j] < 0x7f) j++;
        return [[NSString alloc] initWithBytes:b + i length:j - i encoding:NSASCIIStringEncoding];
    }
    return nil;
}

// The code signature of a Mach-O: its CodeDirectory (identifier, team, flags) and whether a certificate (CMS) signs it, and whose.
static NSString *sig_info(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!d) return @"unreadable";
    const uint8_t *b = d.bytes; size_t n = d.length;
    const struct mach_header_64 *mh = (const void *)b;
    if (n < sizeof *mh || mh->magic != MH_MAGIC_64) return @"not a thin arm64 Mach-O";
    uint32_t off = 0, size = 0; const uint8_t *lc = b + sizeof *mh;
    for (uint32_t i = 0; i < mh->ncmds && lc + sizeof(struct load_command) <= b + n; i++) {
        const struct load_command *c = (const void *)lc;
        if (c->cmd == LC_CODE_SIGNATURE) { const struct linkedit_data_command *s = (const void *)c; off = s->dataoff; size = s->datasize; }
        lc += c->cmdsize;
    }
    if (!off) return @"no code signature";
    if ((size_t)off + size > n || size < 12) return @"signature outside the file";
    const uint8_t *sb = b + off; uint32_t count = be32(sb + 8);
    NSMutableString *out = [NSMutableString string]; BOOL cms = NO;
    for (uint32_t i = 0; i < count && 12 + i * 8 + 8 <= size; i++) {
        uint32_t type = be32(sb + 12 + i * 8), o = be32(sb + 16 + i * 8);
        if (o + 8 > size) continue;
        const uint8_t *bl = sb + o; uint32_t magic = be32(bl), len = be32(bl + 4);
        if (o + len > size) continue;
        if (magic == 0xfade0c02 && type == 0) {   // the primary CodeDirectory
            uint32_t ver = be32(bl + 8), flags = be32(bl + 12), io = be32(bl + 20), to = ver >= 0x20200 ? be32(bl + 48) : 0;
            [out appendFormat:@"identifier %s, team %s, flags %#x%@; ", io < len ? (const char *)bl + io : "?",
                              to && to < len ? (const char *)bl + to : "none", flags, (flags & 0x2) ? @" (adhoc)" : @""];
        } else if (magic == 0xfade0b01) {         // the CMS signature: present and non-empty only with a certificate
            cms = len > 8;
            NSString *who = nil;
            static const char *names[] = {"Apple Development", "iPhone Developer", "Apple Distribution", "iPhone Distribution", "Developer ID"};
            for (size_t k = 0; k < sizeof names / sizeof *names && !who; k++) who = find_text(bl, len, names[k]);
            [out appendFormat:@"CMS %u bytes, signer %@", len - 8, who ?: @"(no known certificate name)"];
        } else if (magic == 0xfade7171 || magic == 0xfade7172) {
            // The entitlements the signature carries, in XML and in the DER form iOS 15+ reads. This is what tells
            // "the same rights as the app" from "none": a framework signed by the installer carries the app's, and
            // a framework the app signs itself carries none unless it is told to.
            NSString *appID = find_text(bl, len, "application-identifier");
            NSRange markup = appID ? [appID rangeOfString:@"<string>"] : NSMakeRange(NSNotFound, 0);
            if (markup.location != NSNotFound) {
                appID = [appID substringFromIndex:NSMaxRange(markup)];
                NSRange end = [appID rangeOfString:@"</string>"];
                if (end.location != NSNotFound) appID = [appID substringToIndex:end.location];
            }
            [out appendFormat:@"; %@ %u bytes%@", magic == 0xfade7171 ? @"entitlements" : @"DER entitlements",
                  len - 8, appID ? [NSString stringWithFormat:@" (application-identifier %@)", appID] : @" (none)"];
        }
    }
    if (!cms) [out appendString:@"; no certificate (ad hoc)"];
    return out;
}

// What the installer put in the app's provisioning profile: the kind of certificate and the team.
static NSString *profile_info(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return @"none (not installed with a developer or enterprise profile)";
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, d.length)];
    NSRange z = [d rangeOfData:[@"</plist>" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, d.length)];
    if (a.location == NSNotFound || z.location == NSNotFound) return @"unreadable";
    NSDictionary *p = [NSPropertyListSerialization propertyListWithData:[d subdataWithRange:NSMakeRange(a.location, NSMaxRange(z) - a.location)]
                                                                options:0 format:NULL error:nil];
    return [NSString stringWithFormat:@"name '%@', team %@, expires %@, devices %@, all devices (enterprise) %@, get-task-allow %@",
            p[@"Name"], [p[@"TeamIdentifier"] firstObject], p[@"ExpirationDate"],
            p[@"ProvisionedDevices"] ? @([p[@"ProvisionedDevices"] count]) : @"none",
            p[@"ProvisionsAllDevices"] ?: @NO, p[@"Entitlements"][@"get-task-allow"] ?: @"?"];
}

static BOOL replace_item(NSString *src, NSString *dst) {
    NSFileManager *fm = NSFileManager.defaultManager; NSError *err = nil;
    [fm removeItemAtPath:dst error:nil];
    [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:&err]) { L(@"copy %@ -> %@ failed: %@", src, dst, err); return NO; }
    return YES;
}

#pragma mark - Phase 0c: the app signs a framework itself

// The CodeDirectory identifier of a Mach-O: what iOS is believed to require of code loaded from outside the bundle.
static NSString *code_directory_identifier(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!d) return nil;
    const uint8_t *b = d.bytes; size_t n = d.length;
    const struct mach_header_64 *mh = (const void *)b;
    if (n < sizeof *mh || mh->magic != MH_MAGIC_64) return nil;
    uint32_t off = 0, size = 0; const uint8_t *lc = b + sizeof *mh;
    for (uint32_t i = 0; i < mh->ncmds && lc + sizeof(struct load_command) <= b + n; i++) {
        const struct load_command *c = (const void *)lc;
        if (c->cmd == LC_CODE_SIGNATURE) { const struct linkedit_data_command *s = (const void *)c; off = s->dataoff; size = s->datasize; }
        lc += c->cmdsize;
    }
    if (!off || (size_t)off + size > n || size < 12) return nil;
    const uint8_t *sb = b + off; uint32_t count = be32(sb + 8);
    for (uint32_t i = 0; i < count && 12 + i * 8 + 8 <= size; i++) {
        if (be32(sb + 12 + i * 8) != 0) continue;                       // the primary CodeDirectory
        uint32_t o = be32(sb + 16 + i * 8);
        if (o + 8 > size) continue;
        const uint8_t *bl = sb + o; uint32_t len = be32(bl + 4), io = be32(bl + 20);
        if (be32(bl) != 0xfade0c02 || io >= len) continue;
        return [NSString stringWithUTF8String:(const char *)bl + io];
    }
    return nil;
}

static NSData *de_xor(NSString *path) {
    NSData *x = [NSData dataWithContentsOfFile:path];
    if (!x) return nil;
    NSMutableData *d = [x mutableCopy]; uint8_t *p = d.mutableBytes;
    for (NSUInteger i = 0; i < d.length; i++) p[i] ^= 0x5A;
    return d;
}

// The certificate, from whichever of the two places has one. The environment is for automation only -- the
// simulator cannot show a file picker -- and writes nothing: a real certificate only ever goes to the Keychain.
static NSDictionary *resign_material(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *path = env[@"NXPROBE_P12"], *password = env[@"NXPROBE_PASSWORD"];
    if (path.length) {
        NSData *p12 = [NSData dataWithContentsOfFile:path];
        if (p12) return @{@"p12": p12, @"password": password ?: @"", @"source": @"NXPROBE_P12"};
        L(@"[cert] NXPROBE_P12 is set but unreadable: %@", path);
    }
    NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                    (__bridge id)kSecAttrService: @"dev.nxpocket.probe",
                                    (__bridge id)kSecReturnData: @YES,
                                    (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne} mutableCopy];
    CFTypeRef got = NULL;
    query[(__bridge id)kSecAttrAccount] = @"certificate";
    NSData *p12 = (SecItemCopyMatching((__bridge CFDictionaryRef)query, &got) == errSecSuccess)
        ? CFBridgingRelease(got) : nil;
    got = NULL;
    NSData *pass = nil;
    query[(__bridge id)kSecAttrAccount] = @"password";
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &got) == errSecSuccess) pass = CFBridgingRelease(got);
    if (!p12) return nil;
    return @{@"p12": p12,
             @"password": pass ? [[NSString alloc] initWithData:pass encoding:NSUTF8StringEncoding] ?: @"" : @"",
             @"source": @"keychain"};
}

static BOOL keychain_put(NSString *account, NSData *value) {
    NSDictionary *base = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecAttrService: @"dev.nxpocket.probe",
                           (__bridge id)kSecAttrAccount: account};
    SecItemDelete((__bridge CFDictionaryRef)base);
    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecValueData] = value;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st != errSecSuccess) L(@"[cert] keychain refused %@: OSStatus %d", account, (int)st);
    return st == errSecSuccess;
}

// Signs one Mach-O the way the app will: the .p12 goes to a private temporary file for the length of the call.
// useProfileEntitlements decides what the signature carries: an empty dict (a framework has no rights of its own,
// PLAN.md 3.3) or the app's own, out of its provisioning profile.
static NSString *resign_framework(NSString *framework, NSString *exe, NSString *identifier,
                                  NSString *provision, NSDictionary *material, BOOL useProfileEntitlements,
                                  double *seconds) {
    NSData *p12 = material[@"p12"];
    if (!p12.length) return @"no certificate";
    if (![NSFileManager.defaultManager fileExistsAtPath:provision]) {
        return [NSString stringWithFormat:@"no provisioning profile at %@ (installed without one?)", provision];
    }
    NSString *tmp = NSTemporaryDirectory();
    NSString *p12Path = [tmp stringByAppendingPathComponent:@"probe.p12"];
    NSString *entPath = [tmp stringByAppendingPathComponent:@"probe-entitlements.plist"];
    [p12 writeToFile:p12Path atomically:YES];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:p12Path error:nil];
    // An empty path is what tells zsign to take the entitlements from the profile instead.
    NSString *empty = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict/></plist>\n";
    if (useProfileEntitlements) [NSFileManager.defaultManager removeItemAtPath:entPath error:nil];
    else [empty writeToFile:entPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    char error[512] = {0};
    NSDate *t0 = [NSDate date];
    int status = nxpocket_zsign_sign(p12Path.fileSystemRepresentation,
                                     [(NSString *)material[@"password"] UTF8String],
                                     provision.fileSystemRepresentation,
                                     useProfileEntitlements ? "" : entPath.fileSystemRepresentation,
                                     framework.fileSystemRepresentation,
                                     exe.fileSystemRepresentation,
                                     identifier.UTF8String,
                                     error, (int)sizeof error);
    *seconds = -[t0 timeIntervalSinceNow];
    [NSFileManager.defaultManager removeItemAtPath:p12Path error:nil];
    [NSFileManager.defaultManager removeItemAtPath:entPath error:nil];
    if (status != 0) return [NSString stringWithFormat:@"zsign: %s", error[0] ? error : "refused without a reason"];
    return nil;
}

// One of tests 5A/5B: take a framework out of the bundle (XOR'ed, so the sideloader never signed it), write it into
// Documents, sign it there, then load it and run its remapped code page.
static result_t resign_test(NSString *tag, NSString *xorName, NSString *exe, NSString *identifier,
                            int want, const char *symbol, NSDictionary *material, NSString *docs,
                            BOOL useProfileEntitlements) {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSData *binary = de_xor([bundle stringByAppendingPathComponent:xorName]);
    if (!binary.length) { L(@"[%@] %@ missing from the bundle", tag, xorName); return R_FAIL; }
    NSString *dir = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"resign/%@.framework", exe]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:exe];
    if (![binary writeToFile:path atomically:YES]) { L(@"[%@] cannot write %@", tag, path); return R_FAIL; }
    NSString *plist = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n"
        "\t<key>CFBundleExecutable</key><string>%@</string>\n"
        "\t<key>CFBundleIdentifier</key><string>%@</string>\n"
        "\t<key>CFBundlePackageType</key><string>FMWK</string>\n"
        "\t<key>CFBundleShortVersionString</key><string>1.0</string>\n"
        "\t<key>CFBundleVersion</key><string>1</string>\n\t<key>MinimumOSVersion</key><string>26.0</string>\n"
        "</dict>\n</plist>\n", exe, identifier];
    [plist writeToFile:[dir stringByAppendingPathComponent:@"Info.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    L(@"[%@] before: %@", tag, sig_info(path));
    double seconds = 0;
    // The app's own profile: zsign reads the team and the entitlements from it, not from the certificate. The
    // environment override exists for the same reason NXPROBE_P12 does -- a simulator app is never provisioned,
    // so its bundle has none -- and changes nothing on a device.
    NSString *provision = NSProcessInfo.processInfo.environment[@"NXPROBE_PROVISION"]
        ?: [bundle stringByAppendingPathComponent:@"embedded.mobileprovision"];
    NSString *failure = resign_framework(dir, exe, identifier, provision, material, useProfileEntitlements, &seconds);
    if (failure) { L(@"[%@] signing failed: %@", tag, failure); return R_FAIL; }
    unsigned long long bytes = binary.length;
    L(@"[%@] signed as '%@' in %.0f ms (%llu bytes, %.1f MB/s; 200 MB would take about %.1f s)", tag, identifier,
      seconds * 1000.0, bytes, seconds > 0 ? (bytes / 1048576.0) / seconds : 0.0,
      seconds > 0 ? 200.0 / ((bytes / 1048576.0) / seconds) : 0.0);
    L(@"[%@] after: %@", tag, sig_info(path));
    NSString *got = code_directory_identifier(path);
    if (![got isEqualToString:identifier]) { L(@"[%@] the signature carries '%@', not '%@'", tag, got, identifier); return R_FAIL; }
    return try_load(tag, path, symbol, want, YES);
}

static void run_probe(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    struct utsname u; uname(&u);
    L(@"---- NXPocket probe %@ (built %s %s) ----", [NSDate date], __DATE__, __TIME__);
    L(@"iOS %@, %s, bundle %@", UIDevice.currentDevice.systemVersion, u.machine, bundle);

    // 1. Baseline: a framework inside the bundle, re-signed by the sideloader (nxnative's DmProbe result).
    result_t r1 = try_load(@"1 bundle", [bundle stringByAppendingPathComponent:@"Frameworks/Probe.framework/Probe"],
                           "probe_answer", 42, NO);

    // Who signed what: the installer's signature on the app and on each nested framework (a real certificate or ad hoc).
    NSString *gsrc = [bundle stringByAppendingPathComponent:@"Frameworks/GameProbe.framework/GameProbe"];
    L(@"[sig] app: %@", sig_info(NSBundle.mainBundle.executablePath));
    L(@"[sig] Probe: %@", sig_info([bundle stringByAppendingPathComponent:@"Frameworks/Probe.framework/Probe"]));
    L(@"[sig] GameProbe: %@", sig_info(gsrc));
    L(@"[sig] embedded.mobileprovision: %@", profile_info([bundle stringByAppendingPathComponent:@"embedded.mobileprovision"]));

    // 2. The key test: the same team's signature, but the file lives in Documents (where a received game would go).
    NSString *gdst = [docs stringByAppendingPathComponent:@"games/GameProbe.framework"];
    result_t r2 = replace_item([bundle stringByAppendingPathComponent:@"Frameworks/GameProbe.framework"], gdst)
        ? try_load(@"2 documents", [gdst stringByAppendingPathComponent:@"GameProbe"], "game_answer", 43, YES) : R_FAIL;
    NSString *gcopy = [gdst stringByAppendingPathComponent:@"GameProbe"];
    L(@"[2 documents] copy is byte-identical to the bundle file: %@ (bundle %@, copy %@)",
      [sha256_of(gsrc) isEqual:sha256_of(gcopy)] ? @"yes" : @"NO", sha256_of(gsrc), sha256_of(gcopy));

    // 2b. A hard link in Documents to the bundle's own file: the same file, another path. Tells "path refused" from "file refused".
    NSString *lnk = [docs stringByAppendingPathComponent:@"link/GameProbe"];
    [NSFileManager.defaultManager removeItemAtPath:lnk.stringByDeletingLastPathComponent error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:lnk.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    result_t r2b = R_SKIP;
    if (link(gsrc.fileSystemRepresentation, lnk.fileSystemRepresentation) == 0)
        r2b = try_load(@"2b hardlink", lnk, "game_answer", 43, YES);
    else L(@"[2b hardlink] link() failed: %s (no conclusion from this test)", strerror(errno));

    // 2c. The same framework from its own place in the bundle: proves the file itself is valid where the installer put it.
    result_t r2c = r2b == R_PASS ? R_SKIP : try_load(@"2c bundle", gsrc, "game_answer", 43, YES);
    L(@"[2] documents %s, hardlink %s, bundle %s", rname(r2), rname(r2b), rname(r2c));

    // 3. A framework the computer signed and pushed (Finder file sharing / Files app) into Documents/Pushed.
    //    Finder's file sharing drops it at the top of Documents, the Files app wherever the user puts it: both places count.
    NSString *push = [docs stringByAppendingPathComponent:@"Pushed/PushProbe.framework/PushProbe"];
    NSString *top = [docs stringByAppendingPathComponent:@"PushProbe.framework/PushProbe"];
    if (![NSFileManager.defaultManager fileExistsAtPath:push] && [NSFileManager.defaultManager fileExistsAtPath:top]) push = top;
    result_t r3 = [NSFileManager.defaultManager fileExistsAtPath:push]
        ? try_load(@"3 pushed", push, "push_answer", 46, YES)
        : (L(@"[3 pushed] no %@ (optional: see README)", push), R_SKIP);

    // 4. Negative control: an ad-hoc-only dylib (stored XOR'ed in the bundle so the sideloader leaves it alone).
    //    It must be refused, or tests 2 and 3 prove nothing about signatures.
    result_t r4 = R_FAIL;
    NSData *x = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"adhoc.xor"]];
    if (!x) L(@"[4 adhoc] adhoc.xor missing from the bundle");
    else {
        NSMutableData *d = [x mutableCopy]; uint8_t *p = d.mutableBytes;
        for (NSUInteger i = 0; i < d.length; i++) p[i] ^= 0x5A;
        NSString *adst = [docs stringByAppendingPathComponent:@"adhoc/AdhocProbe"];
        [NSFileManager.defaultManager createDirectoryAtPath:adst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![d writeToFile:adst atomically:YES]) L(@"[4 adhoc] cannot write %@", adst);
        else {
            L(@"[4 adhoc] loading it now: expected to be refused (if the app dies here, that is also a refusal)");
            r4 = try_load(@"4 adhoc", adst, "adhoc_answer", 45, NO) == R_PASS ? R_FAIL : R_PASS;
        }
    }

    L(@"summary: 1 bundle %s, 2 documents %s, 3 pushed %s, 4 adhoc refused %s", rname(r1), rname(r2), rname(r3), rname(r4));
    if (r1 != R_PASS)      L(@"RESULT: INCONCLUSIVE - even the bundled framework did not load: check the sideloader re-signed Frameworks/");
    else if (r4 != R_PASS) L(@"RESULT: INCONCLUSIVE - an ad-hoc dylib loaded: signatures are not enforced here (jailbreak? developer setting?)");
    else if (r2 == R_PASS) L(@"RESULT: FEASIBLE - same-team code in Documents loads and its pages remap and run%s",
                             r3 == R_PASS ? ", and so does a computer-signed push" : r3 == R_FAIL ? ", but the computer-signed push was refused (see its line)" : "");
    else if (r2b == R_PASS) L(@"RESULT: BLOCKED (file) - the bundle's own file loads from a Documents path, but a copy of it does not: "
                              "the installer's trust covers only the files it installed (see the [sig] lines)");
    else                   L(@"RESULT: BLOCKED - same-team code in Documents was refused (see the [sig] and [2 ...] lines)");
}

// Phase 0c, the test that decides the project: the app signs the code itself, with the certificate that installed
// it and the app's own signature identifier (5A), then with an identifier of its own (5B). LiveContainer does the
// first of these, and it is the only difference the probe found between a refusal and a load.
result_t g_resign_a, g_resign_b, g_resign_c;
static void run_resign_tests(NSString *docs) {
    g_resign_a = g_resign_b = g_resign_c = R_SKIP;
    NSDictionary *material = resign_material();
    if (!material) {
        L(@"[5 resign] no certificate: use \"Import certificate\" below, or set NXPROBE_P12 and NXPROBE_PASSWORD");
        L(@"RESULT: RESIGN SKIPPED - no certificate was available");
        return;
    }
    L(@"[cert] using the certificate from %@", material[@"source"]);
    NSString *appIdentifier = code_directory_identifier(NSBundle.mainBundle.executablePath);
    L(@"[5 resign] the app's own signature identifier is '%@'", appIdentifier ?: @"(unreadable)");
    if (!appIdentifier) { L(@"[5 resign] the app's identifier cannot be read: nothing to sign with"); 
                          L(@"RESULT: RESIGN FAILED - the app's own signature identifier could not be read");
                          return; }
    g_resign_a = resign_test(@"5A", @"resignA.xor", @"ResignA", appIdentifier, 48, "resign_a", material, docs, NO);
    g_resign_b = resign_test(@"5B", @"resignB.xor", @"ResignB", @"dev.nxpocket.probe.ResignB", 49, "resign_b", material, docs, NO);
    // 5C is 5A with one thing changed: the signature carries the app's own entitlements, out of its provisioning
    // profile, instead of none. It passed on the iPhone on 2026-11-10 where 5A was refused. It writes to its own
    // framework (ResignC), so a 5A image that did load cannot be mistaken for 5C's.
    g_resign_c = resign_test(@"5C", @"resignA.xor", @"ResignC", appIdentifier, 48, "resign_a", material, docs, YES);
    L(@"[5 resign] 5A (the app's identifier) %s, 5B (its own) %s, 5C (the app's, with the profile's entitlements) %s",
      rname(g_resign_a), rname(g_resign_b), rname(g_resign_c));
    if (g_resign_a == R_SKIP || g_resign_c == R_SKIP)
        L(@"RESULT: RESIGN INCONCLUSIVE - this process already loaded a test image; relaunch the app for a clean run");
    else if (g_resign_a == R_PASS) L(@"RESULT: RESIGN OK (A ok, B %s)", g_resign_b == R_PASS ? "ok" : "refused");
    else if (g_resign_c == R_PASS) L(@"RESULT: RESIGN OK (A refused, C ok) - the signature has to carry the app's "
                                      "entitlements; signing without them is what iOS was refusing");
    else L(@"RESULT: RESIGN FAILED - code the app signed itself, with the app's own identifier, was refused in Documents "
           "(see the [5A ...] lines: they carry the signature it wrote)");
}

@interface ProbeVC : UIViewController <UIDocumentPickerDelegate>
@end
@implementation ProbeVC {
    UITextView *_text;
    UIButton *_import;
}
- (NSString *)documents {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
- (void)refresh {
    _text.text = g_log;
    [_text scrollRangeToVisible:NSMakeRange(g_log.length, 0)];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _text = [[UITextView alloc] initWithFrame:self.view.bounds];
    _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _text.editable = NO;
    _text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _text.text = @"running...";
    [self.view addSubview:_text];
    // The only thing the user does by hand. Nothing is written to disk: the .p12 and its password go to the
    // Keychain, and the temporary copy zsign reads lives only for the length of the call.
    // Pinned to the bottom of the safe area: at the top it sat under the notch, in the status bar's own strip, and
    // was both half-covered and outside the 44pt a tap needs.
    _import = [UIButton buttonWithType:UIButtonTypeSystem];
    [_import setTitle:@"Import certificate (.p12)" forState:UIControlStateNormal];
    _import.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _import.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _import.layer.cornerRadius = 10;
    _import.translatesAutoresizingMaskIntoConstraints = NO;
    [_import addTarget:self action:@selector(importTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_import];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_import.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_import.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_import.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [_import.heightAnchor constraintEqualToConstant:50],
    ]];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Keep the log out of both the notch and the button, whatever the device.
    UIEdgeInsets safe = self.view.safeAreaInsets;
    _text.textContainerInset = UIEdgeInsetsMake(safe.top + 8, 12, safe.bottom + 74, 12);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL ran; if (ran) return; ran = YES;
    run_probe();
    run_resign_tests(self.documents);
    [self refresh];
}
- (void)importTapped {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePKCS12] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *p12 = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!p12.length) { L(@"[cert] the picked file could not be read"); [self refresh]; return; }
    L(@"[cert] picked %@ (%lu bytes)", url.lastPathComponent, (unsigned long)p12.length);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Certificate password"
                         message:@"The password of the .p12 exported from SideStore. It is stored in the Keychain, never in a file."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.secureTextEntry = YES;
        field.placeholder = @"password";
    }];
    __weak ProbeVC *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Store and sign" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        NSString *password = alert.textFields.firstObject.text ?: @"";
        BOOL certStored = keychain_put(@"certificate", p12);
        BOOL passwordStored = keychain_put(@"password", [password dataUsingEncoding:NSUTF8StringEncoding]);
        if (!certStored || !passwordStored) { L(@"[cert] the Keychain refused it: nothing usable was stored"); [weakSelf refresh]; return; }
        L(@"[cert] stored in the Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)");
        run_resign_tests(weakSelf.documents);
        [weakSelf refresh];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    g_log = [NSMutableString string];
    g_logPath = [docs stringByAppendingPathComponent:@"probe-log.txt"];
    if (![NSFileManager.defaultManager fileExistsAtPath:g_logPath])
        [NSFileManager.defaultManager createFileAtPath:g_logPath contents:nil attributes:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:[docs stringByAppendingPathComponent:@"Pushed"]
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s
                              options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = AppDelegate.class;
    return c;
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeVC new];
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}

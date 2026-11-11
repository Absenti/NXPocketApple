import XCTest

#if canImport(NXZSign)
import NXZSign
#endif

/// Guards the one failure mode of the signing engine that no build error reports.
///
/// `Signing.swift` reaches the engine through `#if canImport(NXZSign)`. When the module is not importable that
/// condition is simply false, the `#else` branch compiles, and everything still builds: the app just refuses to sign
/// on the device and says so at runtime. That happened for real while wiring the engine in — the xcframework was
/// linked, the module was not visible to the package target that imports it, and nothing failed. This test makes
/// that state visible instead.
///
/// A checkout that has not run tools/build_zsign.sh skips rather than fails: the engine is a build product, and the
/// app is meant to build without it.
final class SigningEngineTests: XCTestCase {
    func testTheEngineAnswersWhenItIsInThisBuild() throws {
        #if canImport(NXZSign)
        // An empty request, so nothing is signed and nothing leaves the process: this only proves the shim is
        // really linked and callable, and that its error path reports through the out-parameter.
        var error = [CChar](repeating: 0, count: 64)
        let status = nxpocket_zsign_sign(nil, nil, nil, nil, nil, nil, nil, &error, 64)
        XCTAssertNotEqual(status, 0, "an incomplete request must be refused")
        XCTAssertEqual(String(cString: error), "the signing request is incomplete")
        #else
        throw XCTSkip("no signing engine in this checkout: run tools/build_zsign.sh and build again")
        #endif
    }
}

import CoreGraphics
import XCTest

@testable import NXShellHost

final class TouchLayoutTests: XCTestCase {
    func testWritesTheEnginesFormInItsOrderAndReadsItBack() throws {
        var layout = TouchLayout()
        layout[.threeD, .a] = .init(dx: -1, dy: 0)
        layout[.twoD, .stick] = .init(dx: 1, dy: -1)
        layout[.twoD, .face] = .init(dx: 0, dy: -2)
        XCTAssertEqual(layout.encoded, "1;2d/face:0,-2/stick:1,-1;3d/a:-1,0")
        XCTAssertEqual(TouchLayout(encoded: layout.encoded), layout)
    }

    func testNothingMovedIsTheBuiltInLayoutAndPassesNothing() {
        var layout = TouchLayout()
        layout[.twoD, .face] = .init(dx: 3, dy: 3)
        layout[.twoD, .face] = .zero
        XCTAssertTrue(layout.isEmpty)
        XCTAssertEqual(layout.encoded, "")
        XCTAssertEqual(TouchLayout(encoded: ""), TouchLayout())
        XCTAssertEqual(TouchLayout(encoded: "1"), TouchLayout())
    }

    func testAValueTheEngineIgnoresWholeReadsAsNoneAtAll() {
        for value in ["2;2d/face:0,0", "1;2d/face:0", "1;2d/face:65,0", "1;2d/face:0,-65", "1;2d/face:0001,0",
                      "1;2d/Face:1,1", "1;2d/face:1,1x", "1x", "1;2d/:1,1", String(repeating: "1;2d/face:1,1", count: 100)] {
            XCTAssertNil(TouchLayout(encoded: value), value)
        }
    }

    func testSkipsAnUnknownLayoutOrControlAsTheEngineDoes() throws {
        let layout = try XCTUnwrap(TouchLayout(encoded: "1;9z/face:1,1;2d/zz:1,1/stick:2,2;3d"))
        XCTAssertEqual(layout.encoded, "1;2d/stick:2,2")
    }

    func testClampsAnOffsetToTheEnginesSteps() {
        var layout = TouchLayout()
        layout[.twoD, .plus] = .init(dx: 200, dy: -200)
        XCTAssertEqual(layout[.twoD, .plus], .init(dx: 64, dy: -64))
    }

    func testTheLongestPossibleValueStaysUnderTheEnginesLimit() throws {
        var layout = TouchLayout()
        for kind in TouchLayout.Kind.allCases {
            for control in TouchLayout.Control.allCases { layout[kind, control] = .init(dx: -64, dy: -64) }
        }
        XCTAssertLessThanOrEqual(layout.encoded.utf8.count, TouchLayout.maxLength)
        XCTAssertEqual(TouchLayout(encoded: layout.encoded), layout)
    }
}

final class TouchControlsStorageTests: XCTestCase {
    private var documents: URL!

    override func setUpWithError() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-touch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: documents) }

    func testKeepsTheOptionsForEveryGame() throws {
        var layout = TouchLayout()
        layout[.twoD, .zl] = .init(dx: 2, dy: 4)
        let controls = TouchControls(size: .large, stick: .higher, layout: layout)
        try controls.save(documents: documents)
        XCTAssertEqual(TouchControls.load(documents: documents), controls)
    }

    func testABadFileNeverReachesAGame() throws {
        try FileManager.default.createDirectory(at: SettingsFolder.url(documents: documents), withIntermediateDirectories: true)
        let url = TouchControls.url(documents: documents)
        try Data(#"{"size": "huge", "stick": "inward", "layout": "1;2d/face:99,0"}"#.utf8).write(to: url)
        XCTAssertEqual(TouchControls.load(documents: documents), TouchControls(stick: .inward))
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(TouchControls.load(documents: documents), TouchControls())
    }
}

/// The Swift copy of `DmPadGeometry.h` against what the engine's header computes: the points below come from a small program
/// built on the Mac against `engine/dm/ios/Sources/DmPadGeometry.h` (with the engine's own UIKit stand-in,
/// `dm/ios/tests/pad_geometry`), for an iPhone 15 Pro held sideways (852 × 393, insets 59 / 21 / 59) and a Pro Max.
final class PadGeometryTests: XCTestCase {
    private let phone = PadGeometry.Screen(size: CGSize(width: 852, height: 393), top: 0, left: 59, bottom: 21, right: 59)
    private let proMax = PadGeometry.Screen(size: CGSize(width: 932, height: 430), top: 0, left: 59, bottom: 21, right: 59)

    private func geometry(_ screen: PadGeometry.Screen, _ kind: TouchLayout.Kind, size: TouchControls.Size = .medium,
                          stick: TouchControls.Stick = .corner, layout: String = "") throws -> PadGeometry {
        PadGeometry.make(screen, kind: kind, controls: TouchControls(size: size, stick: stick,
                                                                     layout: try XCTUnwrap(TouchLayout(encoded: layout))))
    }

    private func assertPoint(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat, _ what: String, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 0.001, what, line: line)
        XCTAssertEqual(p.y, y, accuracy: 0.001, what, line: line)
    }

    func testTheBuiltInPlacesAreTheEngines() throws {
        let g = try geometry(phone, .twoD)
        XCTAssertEqual(g.u, 0.913953, accuracy: 0.000_001)
        assertPoint(g.face, 748.4698, 297.0558, "diamond")
        assertPoint(g.faceKey[0], 794.1674, 297.0558, "A")
        assertPoint(g.faceKey[2], 748.4698, 251.3581, "X")
        assertPoint(g.stick, 103.5302, 297.0558, "stick")
        assertPoint(g.dpad, 240.6233, 313.5070, "D-pad")
        assertPoint(g.drop[0], 99.2140, 36.5581, "ZL")
        assertPoint(g.drop[3], 752.7860, 98.7070, "R")
        XCTAssertEqual(g.dropR[1], 21.9349, accuracy: 0.001)
        assertPoint(g.click[1], 699.7767, 36.5581, "R3")
        assertPoint(g.pill[0].origin, 355.6256, 7.3116, "−")
        XCTAssertEqual(g.pill[0].width, 45.6977, accuracy: 0.001)
        assertPoint(g.swap, 426, 20.1070, "menu")
        XCTAssertTrue(g.fits(full: false))
        XCTAssertTrue(try geometry(phone, .threeD).fits(full: true))
    }

    func testTheSizeAndTheStickPlaceAreTheEngines() throws {
        let large = try geometry(phone, .threeD, size: .large, stick: .inward)
        XCTAssertEqual(large.u, 1.096744, accuracy: 0.000_001)
        assertPoint(large.face, 733.6637, 282.0670, "diamond")
        assertPoint(large.stick, 184.1409, 282.0670, "stick moved inward")
        assertPoint(large.dpad, 348.6526, 301.8084, "the D-pad goes along")
        let small = try geometry(phone, .twoD, size: .small, stick: .higher)
        XCTAssertEqual(small.u, 0.731163, accuracy: 0.000_001)
        assertPoint(small.stick, 88.7242, 260.8633, "stick lifted")
        assertPoint(small.dpad, 198.3986, 325.2056, "D-pad")
        let max = try geometry(proMax, .threeD, size: .large, stick: .higher, layout: "1;3d/face:-8,-4/l3:4,4")
        XCTAssertEqual(max.u, 1.2, accuracy: 0.000_001)
        assertPoint(max.stick, 126.7, 250.6, "stick lifted on a Pro Max")
        assertPoint(max.face, 675.7, 245.8, "diamond moved")
        assertPoint(max.click[0], 246.2, 112.8, "L3 moved")
        XCTAssertEqual(max.moved, [.face, .l3])
    }

    func testTheArrangementMovesWhatFitsAndKeepsTheRestAsTheEngineDoes() throws {
        let g = try geometry(phone, .twoD, layout: "1;2d/face:-4,-6/stick:6,-8/zl:3,4/minus:-10,2")
        XCTAssertEqual(g.moved, [.face, .stick, .minus])
        XCTAssertEqual(g.dropped, [.zl])
        assertPoint(g.face, 699.1163, 223.0256, "diamond")
        assertPoint(g.faceKey[1], 699.1163, 268.7233, "B goes with it")
        assertPoint(g.stick, 177.5605, 198.3488, "stick")
        assertPoint(g.pill[0].origin, 232.2419, 31.9884, "−")
        assertPoint(g.drop[0], 99.2140, 36.5581, "ZL kept at its place")

        let three = try geometry(phone, .threeD, layout: "1;3d/a:-4,0/dpad:64,-20/r3:0,64/plus:20,0")
        XCTAssertEqual(three.moved, [.r3])
        XCTAssertEqual(three.dropped, [.a, .dpad, .plus])
        assertPoint(three.click[1], 699.7767, 356.4628, "R3 stopped at the bottom edge")

        let edge = try geometry(phone, .threeD, layout: "1;3d/stick:30,0/dpad:-64,0")
        XCTAssertEqual(edge.moved, [.stick, .dpad])
        assertPoint(edge.stick, 473.6814, 297.0558, "stick")
        assertPoint(edge.dpad, 76.0399, 313.5070, "D-pad stopped at the left edge")
    }

    func testAnotherLayoutsArrangementDoesNotMoveThisOne() throws {
        let g = try geometry(phone, .twoD, size: .large, layout: "1;2d/face:-64,-64/stick:64,-64;3d/x:1,1;2s/zr:3,3")
        XCTAssertEqual(g.u, 1.096744, accuracy: 0.000_001)
        XCTAssertEqual(g.moved, [])
        XCTAssertEqual(g.dropped, [.face, .stick])
        XCTAssertEqual(try geometry(phone, .twoD, layout: "1;3d/x:1,1").moved, [])
    }

    func testTheEditorTakesTheControlUnderTheFinger() throws {
        let g = try geometry(phone, .threeD)
        XCTAssertEqual(g.control(at: g.faceKey[0], full: true, keysApart: false), .face)
        XCTAssertEqual(g.control(at: g.faceKey[0], full: true, keysApart: true), .a)
        XCTAssertEqual(g.control(at: g.stick, full: true, keysApart: false), .stick)
        XCTAssertEqual(g.control(at: g.dpad, full: true, keysApart: false), .dpad)
        XCTAssertEqual(g.control(at: CGPoint(x: g.pill[1].midX, y: g.pill[1].midY), full: true, keysApart: false), .plus)
        XCTAssertNotEqual(g.control(at: g.dpad, full: false, keysApart: false), .dpad, "no D-pad in 2D")
        XCTAssertNil(g.control(at: CGPoint(x: 426, y: 200), full: true, keysApart: false), "the middle of the picture")
        XCTAssertNil(g.control(at: g.swap, full: true, keysApart: false), "the menu button does not move")
    }

    func testAControlDraggedPastTheEdgeIsKeptWhereItStopped() throws {
        var layout = TouchLayout()
        layout[.twoD, .stick] = .init(dx: -30, dy: 0)
        let controls = TouchControls(layout: layout)
        let dragged = PadGeometry.make(phone, kind: .twoD, controls: controls)
        let placed = PadGeometry.make(phone, kind: .twoD, controls: TouchControls())
        XCTAssertEqual(dragged.moved, [.stick], "the engine stops it at the edge of its area")
        let settled = TouchLayoutEditor.settled(layout, kind: .twoD, control: .stick, geometry: dragged, placed: placed) {
            PadGeometry.make(self.phone, kind: .twoD, controls: TouchControls(layout: $0))
        }
        let after = PadGeometry.make(phone, kind: .twoD, controls: TouchControls(layout: settled))
        XCTAssertGreaterThan(settled[.twoD, .stick].dx, -30, "the kept offset says where the stick stopped")
        XCTAssertEqual(after.stick.x, dragged.stick.x, accuracy: placed.step, "and puts it there")
        XCTAssertTrue(after.dropped.isEmpty)
    }
}

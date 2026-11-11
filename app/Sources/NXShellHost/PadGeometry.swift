import CoreGraphics
import Foundation

/// Where the engine draws the touch controls on an iPhone held sideways: a Swift copy of the engine's `DmPadGeometry.h`
/// (`dm_pad_geo_at`, the fit test, the size and stick-place fallbacks, `dm_pad_arrange`), line for line, so the layout editor
/// shows and keeps only what the engine will draw. Only the overlay layout is copied: a game on the iPhone is always
/// landscape, so the split layout of an iPad held upright or a foldable never applies here. `PadGeometryTests` pins it to
/// points the engine's own header computes; on the device, the engine stays the truth.
struct PadGeometry: Equatable {
    /// The game view as the engine sees it: its size in points and its safe-area insets.
    struct Screen: Equatable {
        var size: CGSize
        var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0

        func inset(_ r: CGRect, horizontalFactor: CGFloat = 1) -> CGRect {
            CGRect(x: r.minX + left * horizontalFactor, y: r.minY + top,
                   width: r.width - (left + right) * horizontalFactor, height: r.height - top - bottom)
        }
        var bounds: CGRect { CGRect(origin: .zero, size: size) }
        /// The picture: the largest centred 16:9 rectangle (`dm_aspect_fit`), what the editor shows behind the controls.
        var picture: CGRect {
            var w = size.width, h = size.height
            guard w > 0, h > 0 else { return .zero }
            if w / h > 16.0 / 9.0 { w = h * 16.0 / 9.0 } else { h = w * 9.0 / 16.0 }
            return CGRect(x: floor(size.width / 2 - w / 2), y: floor(size.height / 2 - h / 2), width: w, height: h)
        }
    }

    /// One drawn shape, a circle or a rectangle, with the rectangle it has to stay inside (`DmPadShape`).
    struct Shape: Equatable {
        var c: CGPoint = .zero
        var r: CGFloat = 0
        var rect: CGRect = .null
        var isRect = false
        var within: CGRect
        var id: Int
        var box: CGRect { isRect ? rect : CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
    }

    // `dm_pad_shapes` ids.
    static let shapeFace = 0, shapeStick = 4, shapeDpad = 5, shapeDrop = 6, shapeTip = 10, shapeClick = 14, shapePill = 16, shapeSwap = 18
    // Indices of `drop` (ZL, L, ZR, R) and `pill` (−, +).
    static let zl = 0, zr = 2, minus = 0, plus = 1

    var u: CGFloat = 0
    var safe: CGRect = .null, corner: CGRect = .null
    var face: CGPoint = .zero, faceGap: CGFloat = 0, faceR: CGFloat = 0, faceHitR: CGFloat = 0
    var stick: CGPoint = .zero, stickR: CGFloat = 0, knobR: CGFloat = 0
    var dpad: CGPoint = .zero, dpadR: CGFloat = 0, armW: CGFloat = 0, armIn: CGFloat = 0
    var drop: [CGPoint] = Array(repeating: .zero, count: 4), dropR: [CGFloat] = Array(repeating: 0, count: 4)
    var click: [CGPoint] = [.zero, .zero], clickR: CGFloat = 0
    var pill: [CGRect] = [.zero, .zero]
    var swap: CGPoint = .zero, swapR: CGFloat = 0
    var faceKey: [CGPoint] = Array(repeating: .zero, count: 4)   // A B X Y where they are
    var faceSplit = false
    /// The controls the arrangement moved, and the ones it asked to move that kept their place (no room there).
    var moved: Set<TouchLayout.Control> = [], dropped: Set<TouchLayout.Control> = []

    /// One step of the arrangement: a quarter of a face key's width.
    var step: CGFloat { faceR / 2 }

    // MARK: - dm_pad_geo_at, with no fitting

    static func side(_ s: CGRect, right: Bool, _ dx: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: right ? s.maxX - dx : s.minX + dx, y: y)
    }

    /// A key of the diamond around `c`: A right, B bottom, X top, Y left.
    static func diamondKey(_ c: CGPoint, _ d: CGFloat, _ i: Int) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: c.x + d, y: c.y)
        case 1: return CGPoint(x: c.x, y: c.y + d)
        case 2: return CGPoint(x: c.x, y: c.y - d)
        default: return CGPoint(x: c.x - d, y: c.y)
        }
    }

    static func at(_ screen: Screen, full: Bool, u: CGFloat) -> PadGeometry {
        var g = PadGeometry()
        g.u = u
        g.safe = screen.inset(screen.bounds)
        // The bottom-corner controls reach halfway into the side insets: only the rounded corner is there in landscape.
        g.corner = screen.inset(screen.bounds, horizontalFactor: 0.5)
        let s = g.safe, c = g.corner
        g.faceGap = 50 * u; g.faceR = 27 * u; g.faceHitR = g.faceR * 1.25
        g.stickR = 77 * u; g.knobR = 30 * u
        g.dpadR = 48 * u; g.armW = 17 * u; g.armIn = 11 * u
        g.face = side(c, right: true, 81 * u, c.maxY - 82 * u)
        g.stick = side(c, right: false, 81 * u, c.maxY - 82 * u)
        g.dpad = side(c, right: false, 231 * u, c.maxY - 64 * u)
        for i in 0..<4 {
            let z = i == zl || i == zr
            g.drop[i] = side(s, right: i >= zr, 44 * u, s.minY + (z ? 40 : 108) * u)
            g.dropR[i] = (z ? 26 : 24) * u
        }
        for i in 0..<2 { g.click[i] = side(s, right: i == 1, 102 * u, s.minY + 40 * u) }
        g.clickR = 17 * u
        let top = s.minY + 22 * u, w = 50 * u, h = 28 * u
        for i in 0..<2 {
            let x = s.midX + (i == plus ? 52 : -52) * u   // − on the left, + on the right
            g.pill[i] = CGRect(x: x - w / 2, y: top - h / 2, width: w, height: h)
        }
        g.swap = CGPoint(x: s.midX, y: top); g.swapR = 15 * u
        for i in 0..<4 { g.faceKey[i] = diamondKey(g.face, g.faceGap, i) }
        return g
    }

    /// The tip of a teardrop (ZL, L, ZR, R), toward the near top corner.
    func dropTip(_ i: Int) -> CGPoint {
        let a = i >= Self.zr ? -CGFloat.pi / 4 : -3 * CGFloat.pi / 4, d = dropR[i] * 1.45
        return CGPoint(x: drop[i].x + d * cos(a), y: drop[i].y + d * sin(a))
    }

    // MARK: - The fit test

    func shapes(full: Bool) -> [Shape] {
        var out: [Shape] = []
        for i in 0..<4 { out.append(Shape(c: faceKey[i], r: faceR, within: corner, id: Self.shapeFace + i)) }
        out.append(Shape(c: stick, r: stickR, within: corner, id: Self.shapeStick))
        if full { out.append(Shape(c: dpad, r: hypot(dpadR, armW), within: corner, id: Self.shapeDpad)) }
        for i in 0..<4 {
            out.append(Shape(c: drop[i], r: dropR[i], within: safe, id: Self.shapeDrop + i))
            out.append(Shape(c: dropTip(i), r: 0, within: safe, id: Self.shapeTip + i))
        }
        if full { for i in 0..<2 { out.append(Shape(c: click[i], r: clickR, within: safe, id: Self.shapeClick + i)) } }
        for i in 0..<2 { out.append(Shape(rect: pill[i], isRect: true, within: safe, id: Self.shapePill + i)) }
        out.append(Shape(c: swap, r: swapR, within: safe, id: Self.shapeSwap))
        return out
    }

    static func inside(_ s: Shape) -> Bool {
        let e: CGFloat = 0.5, b = s.box
        return b.minX >= s.within.minX - e && b.maxX <= s.within.maxX + e && b.minY >= s.within.minY - e && b.maxY <= s.within.maxY + e
    }

    static func overlap(_ a: Shape, _ b: Shape) -> Bool {
        let e: CGFloat = 0.5
        if a.isRect && b.isRect { return a.rect.insetBy(dx: e, dy: e).intersects(b.rect.insetBy(dx: e, dy: e)) }
        if a.isRect || b.isRect {
            let r = a.isRect ? a : b, c = a.isRect ? b : a
            let nx = Swift.max(r.rect.minX, Swift.min(c.c.x, r.rect.maxX)), ny = Swift.max(r.rect.minY, Swift.min(c.c.y, r.rect.maxY))
            return hypot(c.c.x - nx, c.c.y - ny) < c.r - e
        }
        return hypot(a.c.x - b.c.x, a.c.y - b.c.y) < a.r + b.r - e
    }

    /// A teardrop's tip belongs to its own circle.
    static func sameControl(_ a: Shape, _ b: Shape) -> Bool {
        (a.id >= shapeDrop && a.id < shapeTip && b.id == a.id + 4) || (b.id >= shapeDrop && b.id < shapeTip && a.id == b.id + 4)
    }

    /// Every drawn shape inside its rectangle and no two overlapping (`dm_pad_geo_fits`).
    func fits(full: Bool) -> Bool {
        let s = shapes(full: full)
        for i in s.indices {
            if !Self.inside(s[i]) { return false }
            for j in s.indices where j > i && !Self.sameControl(s[i], s[j]) && Self.overlap(s[i], s[j]) { return false }
        }
        return true
    }

    // MARK: - The player's size and stick place (dm_pad_geo_placed)

    /// The built-in size's unit: the screen height, 1 being 430 points, up to 1.3.
    static func baseUnit(_ screen: Screen) -> CGFloat { Swift.min(screen.size.height / 430, 1.3) }

    static func placed(_ screen: Screen, full: Bool, size: TouchControls.Size, stick: TouchControls.Stick) -> PadGeometry {
        let u0 = baseUnit(screen)
        var scale = size.scale
        var g = at(screen, full: full, u: u0 * scale)
        // A size that does not fit moves toward the built-in size in steps; the built-in size is never changed.
        while scale != 1 && !g.fits(full: full) {
            scale = scale > 1 ? Swift.max(1, scale - 0.05) : Swift.min(1, scale + 0.05)
            g = at(screen, full: full, u: u0 * scale)
        }
        guard stick != .corner else { return g }
        // Higher lifts the stick toward the shoulders, inward moves it and the D-pad toward the middle; the move shrinks in
        // steps until nothing overlaps, and on a screen with no room the stick stays in the corner.
        let up = stick == .higher, stick0 = g.stick, dpad0 = g.dpad
        var d = (up ? 70 : 60) * g.u
        while d > 0 {
            if up {
                g.stick = CGPoint(x: stick0.x, y: stick0.y - d)
            } else {
                g.stick = CGPoint(x: stick0.x + d, y: stick0.y)
                g.dpad = CGPoint(x: dpad0.x + d, y: dpad0.y)
            }
            if g.fits(full: full) { return g }
            d -= 2 * g.u
        }
        g.stick = stick0; g.dpad = dpad0
        return g
    }

    // MARK: - The player's arrangement (dm_pad_arrange)

    static let moveGap: CGFloat = 10

    static func isShape(_ id: Int, of c: TouchLayout.Control) -> Bool {
        switch c {
        case .face: return id >= shapeFace && id < shapeFace + 4
        case .a: return id == shapeFace
        case .b: return id == shapeFace + 1
        case .x: return id == shapeFace + 2
        case .y: return id == shapeFace + 3
        case .stick: return id == shapeStick
        case .dpad: return id == shapeDpad
        case .l3: return id == shapeClick
        case .r3: return id == shapeClick + 1
        case .minus: return id == shapePill
        case .plus: return id == shapePill + 1
        case .zl, .l, .zr, .r:
            let i = dropIndex(c)
            return id == shapeDrop + i || id == shapeTip + i
        }
    }

    static func dropIndex(_ c: TouchLayout.Control) -> Int {
        switch c { case .zl: return 0; case .l: return 1; case .zr: return 2; default: return 3 }
    }

    mutating func move(_ c: TouchLayout.Control, _ dx: CGFloat, _ dy: CGFloat) {
        func shift(_ p: inout CGPoint) { p.x += dx; p.y += dy }
        switch c {
        case .face:
            shift(&face)
            for i in 0..<4 { shift(&faceKey[i]) }
        case .a: shift(&faceKey[0])
        case .b: shift(&faceKey[1])
        case .x: shift(&faceKey[2])
        case .y: shift(&faceKey[3])
        case .stick: shift(&stick)
        case .dpad: shift(&dpad)
        case .l3: shift(&click[0])
        case .r3: shift(&click[1])
        case .minus: shift(&pill[0].origin)
        case .plus: shift(&pill[1].origin)
        case .zl, .l, .zr, .r: shift(&drop[Self.dropIndex(c)])
        }
    }

    /// `a` closer to `b` than `gap`: `a` grown by the gap all round, a rectangle with square corners.
    static func near(_ a: Shape, _ b: Shape, _ gap: CGFloat) -> Bool {
        var x = a
        if x.isRect { x.rect = x.rect.insetBy(dx: -gap, dy: -gap) } else { x.r += gap }
        return overlap(x, b)
    }

    /// Control `c` where this geometry has it: inside the area its built-in place uses, no nearer than the gap to another
    /// control, and outside the menu button's whole hit circle.
    func controlFits(full: Bool, _ c: TouchLayout.Control) -> Bool {
        let s = shapes(full: full)
        let gap = Swift.max(Self.moveGap * u, Self.moveGap)
        for shape in s where Self.isShape(shape.id, of: c) {
            if !Self.inside(shape) { return false }
            for var other in s where !Self.isShape(other.id, of: c) {
                if other.id == Self.shapeSwap { other.r = Swift.max(other.r + gap, Swift.max(swapR * 1.6, 22)) - gap }
                if Self.near(shape, other, gap) { return false }
            }
        }
        return true
    }

    static func clamp1D(_ lo: CGFloat, _ hi: CGFloat, _ rlo: CGFloat, _ rhi: CGFloat) -> CGFloat {
        if hi - lo > rhi - rlo { return (rlo + rhi) / 2 - (lo + hi) / 2 }
        return lo < rlo ? rlo - lo : hi > rhi ? rhi - hi : 0
    }

    /// How far `c` has to move to be inside its rectangle: a control dragged past the edge stops at the edge.
    func clamp(full: Bool, _ c: TouchLayout.Control) -> CGPoint {
        var x0 = CGFloat.greatestFiniteMagnitude, y0 = CGFloat.greatestFiniteMagnitude
        var x1 = -CGFloat.greatestFiniteMagnitude, y1 = -CGFloat.greatestFiniteMagnitude
        var within = CGRect.null
        for shape in shapes(full: full) where Self.isShape(shape.id, of: c) {
            let b = shape.box
            within = shape.within
            x0 = Swift.min(x0, b.minX); y0 = Swift.min(y0, b.minY); x1 = Swift.max(x1, b.maxX); y1 = Swift.max(y1, b.maxY)
        }
        guard !within.isNull else { return .zero }
        return CGPoint(x: Self.clamp1D(x0, x1, within.minX, within.maxX), y: Self.clamp1D(y0, y1, within.minY, within.maxY))
    }

    /// The arrangement of one layout, on top of the size and the stick place. Two rounds: the diamond and the other controls,
    /// then the diamond's keys on their own from where the diamond ended up. Each round places every control that fits and
    /// tries the rest again; a control that never fits keeps its place and is reported in `dropped`.
    mutating func arrange(full: Bool, kind: TouchLayout.Kind, layout: TouchLayout) {
        let step = self.step
        let want = TouchLayout.Control.allCases.filter { $0.drawn(full: full) && !layout[kind, $0].isZero }
        for round in 0..<2 {
            var todo = want.filter { $0.isFaceKey == (round == 1) }
            var progress = true
            while !todo.isEmpty && progress {
                progress = false
                for c in TouchLayout.Control.allCases where todo.contains(c) {
                    var t = self
                    let o = layout[kind, c]
                    t.move(c, CGFloat(o.dx) * step, CGFloat(o.dy) * step)
                    let d = t.clamp(full: full, c)
                    t.move(c, d.x, d.y)
                    guard t.controlFits(full: full, c) else { continue }
                    self = t
                    moved.insert(c)
                    todo.removeAll { $0 == c }
                    progress = true
                    if c.isFaceKey { faceSplit = true }
                }
            }
            dropped.formUnion(todo)
        }
    }

    /// What the gamepad draws on this screen (`dm_pad_geo`): the size and the stick place, then the arrangement of `kind`.
    static func make(_ screen: Screen, kind: TouchLayout.Kind, controls: TouchControls) -> PadGeometry {
        var g = placed(screen, full: kind.full, size: controls.size, stick: controls.stick)
        g.arrange(full: kind.full, kind: kind, layout: controls.layout)
        return g
    }

    // MARK: - For the editor

    /// The control a touch at `p` takes in the editor: the nearest whose shape it lands on, with some room around small
    /// ones. The diamond answers as a whole unless `keysApart`.
    func control(at p: CGPoint, full: Bool, keysApart: Bool) -> TouchLayout.Control? {
        var best: (control: TouchLayout.Control, distance: CGFloat)?
        func consider(_ c: TouchLayout.Control, _ distance: CGFloat) {
            if distance <= 1, distance < best?.distance ?? .greatestFiniteMagnitude { best = (c, distance) }
        }
        let all = shapes(full: full).filter { !($0.id >= Self.shapeTip && $0.id < Self.shapeClick) }   // a tip is a point
        for c in TouchLayout.Control.allCases where c.drawn(full: full) && c != .face && (keysApart || !c.isFaceKey) {
            for shape in all where Self.isShape(shape.id, of: c) {
                if shape.isRect {
                    consider(c, shape.rect.insetBy(dx: -8, dy: -8).contains(p) ? 0 : .greatestFiniteMagnitude)
                } else {
                    consider(c, hypot(p.x - shape.c.x, p.y - shape.c.y) / Swift.max(shape.r * 1.15, 22))
                }
            }
        }
        if !keysApart { consider(.face, hypot(p.x - face.x, p.y - face.y) / (faceGap + faceR * 1.3)) }
        return best?.control
    }

    /// Where control `c` is drawn, as one point: what a drag moves.
    func anchor(of c: TouchLayout.Control) -> CGPoint {
        switch c {
        case .face: return face
        case .a: return faceKey[0]
        case .b: return faceKey[1]
        case .x: return faceKey[2]
        case .y: return faceKey[3]
        case .stick: return stick
        case .dpad: return dpad
        case .l3: return click[0]
        case .r3: return click[1]
        case .minus: return CGPoint(x: pill[0].midX, y: pill[0].midY)
        case .plus: return CGPoint(x: pill[1].midX, y: pill[1].midY)
        case .zl, .l, .zr, .r: return drop[Self.dropIndex(c)]
        }
    }
}

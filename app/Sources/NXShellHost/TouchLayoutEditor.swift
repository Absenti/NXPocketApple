import NXShellUI
import SwiftUI
import UIKit

/// The touch controls as a game draws them, on this phone held sideways, for the player to drag one by one. What it keeps is
/// `TouchControls.layout`, the `DM_TOUCH_LAYOUT` every game reads. The places come from `PadGeometry`, the engine's own
/// rules: a control dropped where the engine would keep it at its built-in place (off its area, on or too near another one,
/// in the menu button's circle) goes back to where it was, so what this screen shows is what the game will draw.
struct TouchLayoutEditor: View {
    @EnvironmentObject private var model: ShellHostModel
    let close: () -> Void

    @State private var controls: TouchControls
    @State private var kind: TouchLayout.Kind = .twoD
    @State private var keysApart = false
    @State private var drag: Drag?
    @State private var panelLow = false

    /// A drag in progress: the control, its offset when the finger came down, the offset under the finger, and whether the
    /// engine would place it there.
    struct Drag {
        var control: TouchLayout.Control
        var start: TouchLayout.Offset
        var candidate: TouchLayout.Offset
        var fits: Bool
    }

    init(controls: TouchControls, close: @escaping () -> Void) {
        _controls = State(initialValue: controls)
        self.close = close
    }

    var body: some View {
        GeometryReader { proxy in
            let screen = Self.screen(for: proxy.size)
            let fit = Self.fit(screen.size, in: proxy.size)
            let geometry = shown(on: screen)
            ZStack {
                Color.black
                Canvas { context, _ in
                    context.translateBy(x: fit.origin.x, y: fit.origin.y)
                    context.scaleBy(x: fit.scale, y: fit.scale)
                    draw(geometry, screen: screen, in: &context)
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragChanged(start: fit.toScreen(value.startLocation), now: fit.toScreen(value.location), screen: screen)
                    }
                    .onEnded { _ in dragEnded(screen: screen) })
                panel(screen: screen, geometry: geometry, portrait: proxy.size.height > proxy.size.width)
                    .frame(maxWidth: 320)
                    .frame(maxHeight: .infinity, alignment: panelLow ? .bottom : .top)
                    .padding(.vertical, fit.scale < 1 ? 24 : screen.size.height * 0.16)
                    .opacity(drag == nil ? 1 : 0.2)
                    .allowsHitTesting(drag == nil)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    // MARK: - The screen and its geometry

    /// The game view: this window in landscape, with its safe area. Until the phone has turned, a landscape screen of the
    /// same device, its insets taken from the portrait ones, drawn smaller.
    static func screen(for size: CGSize) -> PadGeometry.Screen {
        let insets = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
        if size.width >= size.height {
            return PadGeometry.Screen(size: size, top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
        }
        let side = Swift.max(insets.top, insets.bottom)
        return PadGeometry.Screen(size: CGSize(width: size.height, height: size.width), top: 0, left: side,
                                  bottom: insets.bottom > 0 ? 21 : 0, right: side)
    }

    struct Fit {
        var origin: CGPoint
        var scale: CGFloat
        func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
    }

    static func fit(_ screen: CGSize, in view: CGSize) -> Fit {
        let scale = Swift.min(1, view.width / Swift.max(screen.width, 1), view.height / Swift.max(screen.height, 1))
        return Fit(origin: CGPoint(x: (view.width - screen.width * scale) / 2, y: (view.height - screen.height * scale) / 2),
                   scale: scale)
    }

    private func geometry(_ layout: TouchLayout, on screen: PadGeometry.Screen) -> PadGeometry {
        var trial = controls
        trial.layout = layout
        return PadGeometry.make(screen, kind: kind, controls: trial)
    }

    /// What is drawn: the drag's place while the engine would take it, else the kept arrangement.
    private func shown(on screen: PadGeometry.Screen) -> PadGeometry {
        guard let drag, drag.fits else { return geometry(controls.layout, on: screen) }
        var layout = controls.layout
        layout[kind, drag.control] = drag.candidate
        return geometry(layout, on: screen)
    }

    // MARK: - Dragging

    private func dragChanged(start: CGPoint, now: CGPoint, screen: PadGeometry.Screen) {
        let kept = geometry(controls.layout, on: screen)
        if drag == nil {
            guard let control = kept.control(at: start, full: kind.full, keysApart: keysApart) else { return }
            let offset = controls.layout[kind, control]
            drag = Drag(control: control, start: offset, candidate: offset, fits: true)
        }
        guard var current = drag else { return }
        let step = kept.step
        let moved = TouchLayout.Offset(dx: current.start.dx + Int(((now.x - start.x) / step).rounded()),
                                       dy: current.start.dy + Int(((now.y - start.y) / step).rounded()))
        var layout = controls.layout
        layout[kind, current.control] = moved
        current.candidate = layout[kind, current.control]   // clamped to the engine's ±64
        let trial = geometry(layout, on: screen)
        // The engine places what fits and keeps the rest where it was: the move counts only when it drops nothing that the
        // kept arrangement placed.
        current.fits = !trial.dropped.contains(current.control) && trial.dropped.isSubset(of: kept.dropped)
        drag = current
    }

    private func dragEnded(screen: PadGeometry.Screen) {
        defer { drag = nil }
        guard let drag, drag.fits, drag.candidate != drag.start else { return }
        var layout = controls.layout
        layout[kind, drag.control] = drag.candidate
        controls.layout = Self.settled(layout, kind: kind, control: drag.control, geometry: geometry(layout, on: screen),
                                       placed: geometry(TouchLayout(), on: screen)) { geometry($0, on: screen) }
    }

    /// The engine stops a control dragged past its area's edge at the edge. What is kept is the offset of where it stopped,
    /// rounded toward its built-in place, so the value says where the control is rather than where the finger went; when
    /// that place does not fit, the offset as dragged.
    static func settled(_ layout: TouchLayout, kind: TouchLayout.Kind, control: TouchLayout.Control, geometry: PadGeometry,
                        placed: PadGeometry, arrange: (TouchLayout) -> PadGeometry) -> TouchLayout {
        let step = geometry.step
        guard step > 0 else { return layout }
        var shift = CGPoint(x: geometry.anchor(of: control).x - placed.anchor(of: control).x,
                            y: geometry.anchor(of: control).y - placed.anchor(of: control).y)
        if control.isFaceKey {   // a key's offset is from where the diamond is
            shift.x -= geometry.face.x - placed.face.x
            shift.y -= geometry.face.y - placed.face.y
        }
        func steps(_ v: CGFloat) -> Int {
            let s = v / step
            return abs(s - s.rounded()) < 0.01 ? Int(s.rounded()) : Int(s.rounded(.towardZero))
        }
        var settled = layout
        settled[kind, control] = TouchLayout.Offset(dx: steps(shift.x), dy: steps(shift.y))
        guard settled != layout else { return layout }
        let check = arrange(settled)
        let placedThere = settled[kind, control].isZero || check.moved.contains(control)
        return check.dropped.isSubset(of: geometry.dropped) && placedThere ? settled : layout
    }

    // MARK: - Drawing

    private func draw(_ g: PadGeometry, screen: PadGeometry.Screen, in context: inout GraphicsContext) {
        let picture = screen.picture
        context.fill(Path(screen.bounds), with: .color(.black))
        context.fill(Path(picture), with: .color(ShellInk.surface))
        context.stroke(Path(CGRect(origin: .zero, size: screen.size).insetBy(dx: 0.5, dy: 0.5)), with: .color(ShellInk.line))

        let idle = Color.white.opacity(0.14), line = Color.white.opacity(0.38), label = Color.white.opacity(0.7)
        let dragged = drag?.control
        let ghost = drag.map { !$0.fits } ?? false
        func style(_ c: TouchLayout.Control) -> (fill: Color, stroke: Color) {
            let selected = dragged == c || (dragged == .face && c.isFaceKey && !keysApart)
            if selected && !ghost { return (ShellInk.accent.opacity(0.35), ShellInk.accent) }
            if g.moved.contains(c) || (c.isFaceKey && g.moved.contains(.face)) { return (idle, ShellInk.accent.opacity(0.6)) }
            return (idle, line)
        }
        func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
        func text(_ s: String, at p: CGPoint, size: CGFloat) {
            context.draw(Text(s).font(.system(size: size, weight: .semibold)).foregroundColor(label), at: p)
        }
        func shape(_ path: Path, _ c: TouchLayout.Control) {
            let s = style(c)
            context.fill(path, with: .color(s.fill))
            context.stroke(path, with: .color(s.stroke), lineWidth: 1.5)
        }

        // The left stick: its ring and the knob in the middle.
        shape(circle(g.stick, g.stickR), .stick)
        context.stroke(circle(g.stick, g.knobR), with: .color(line), lineWidth: 1.5)
        // The diamond: A right, B bottom, X top, Y left.
        for (i, name) in ["A", "B", "X", "Y"].enumerated() {
            let c: TouchLayout.Control = [.a, .b, .x, .y][i]
            shape(circle(g.faceKey[i], g.faceR), c)
            text(name, at: g.faceKey[i], size: g.faceR * 0.75)
        }
        if kind.full {
            var cross = Path()
            for a in 0..<4 {
                let angle = CGFloat(a) * .pi / 2
                let arm = CGRect(x: g.armIn, y: -g.armW, width: g.dpadR - g.armIn, height: 2 * g.armW)
                cross.addPath(Path(roundedRect: arm, cornerRadius: g.armW * 0.4),
                              transform: CGAffineTransform(translationX: g.dpad.x, y: g.dpad.y).rotated(by: angle))
            }
            shape(cross, .dpad)
            for (i, name) in ["L3", "R3"].enumerated() {
                shape(circle(g.click[i], g.clickR), i == 0 ? .l3 : .r3)
                text(name, at: g.click[i], size: g.clickR * 0.8)
            }
        }
        for (i, c) in [TouchLayout.Control.zl, .l, .zr, .r].enumerated() {
            shape(teardrop(center: g.drop[i], radius: g.dropR[i], tip: g.dropTip(i)), c)
            text(["ZL", "L", "ZR", "R"][i], at: g.drop[i], size: g.dropR[i] * 0.7)
        }
        for (i, name) in ["−", "+"].enumerated() {
            shape(Path(roundedRect: g.pill[i], cornerRadius: g.pill[i].height / 2), i == 0 ? .minus : .plus)
            text(name, at: CGPoint(x: g.pill[i].midX, y: g.pill[i].midY), size: g.pill[i].height * 0.7)
        }
        // The menu button never moves: drawn dimmer, so it does not read as something to drag.
        context.fill(circle(g.swap, g.swapR), with: .color(Color.white.opacity(0.08)))
        var gear = context.resolve(Image(systemName: "gearshape.fill"))
        gear.shading = .color(Color.white.opacity(0.45))
        context.draw(gear, in: CGRect(x: g.swap.x - g.swapR * 0.6, y: g.swap.y - g.swapR * 0.6, width: g.swapR * 1.2, height: g.swapR * 1.2))

        // Where the finger is, in red, while the engine would not put the control there.
        if let drag, !drag.fits {
            let dx = CGFloat(drag.candidate.dx - drag.start.dx) * g.step, dy = CGFloat(drag.candidate.dy - drag.start.dy) * g.step
            var moved = g
            moved.move(drag.control, dx, dy)
            for s in moved.shapes(full: kind.full) where PadGeometry.isShape(s.id, of: drag.control) && (s.isRect || s.r > 0) {
                let path = s.isRect ? Path(roundedRect: s.rect, cornerRadius: s.rect.height / 2) : circle(s.c, s.r)
                context.fill(path, with: .color(ShellInk.bad.opacity(0.25)))
                context.stroke(path, with: .color(ShellInk.bad), lineWidth: 1.5)
            }
            let at = moved.anchor(of: drag.control)
            context.draw(Text(model.text(.noRoomThere)).font(.system(size: 12, weight: .semibold)).foregroundColor(ShellInk.bad),
                         at: CGPoint(x: at.x, y: at.y - g.faceR * 2.2))
        }
    }

    /// A shoulder key: its circle with a point toward the near top corner, as the gamepad draws it.
    private func teardrop(center c: CGPoint, radius r: CGFloat, tip: CGPoint) -> Path {
        let d = hypot(tip.x - c.x, tip.y - c.y)
        guard d > r else { return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
        let toward = atan2(tip.y - c.y, tip.x - c.x), half = acos(r / d)
        var path = Path()
        path.move(to: tip)
        path.addArc(center: c, radius: r, startAngle: .radians(Double(toward + half)),
                    endAngle: .radians(Double(toward - half + 2 * .pi)), clockwise: false)
        path.closeSubpath()
        return path
    }

    // MARK: - The panel

    private func panel(screen: PadGeometry.Screen, geometry: PadGeometry, portrait: Bool) -> some View {
        VStack(spacing: 10) {
            Picker("", selection: $kind) {
                Text(model.text(.layout2D)).tag(TouchLayout.Kind.twoD)
                Text(model.text(.layout3D)).tag(TouchLayout.Kind.threeD)
            }
            .pickerStyle(.segmented)
            Toggle(model.text(.keysApart), isOn: $keysApart)
                .font(.system(size: 13)).tint(ShellInk.accent).foregroundStyle(ShellInk.primary)
            Text(portrait ? model.text(.turnSideways) : model.text(.editorHint))
                .font(.system(size: 11)).foregroundStyle(ShellInk.secondary).multilineTextAlignment(.center)
            if !geometry.dropped.isEmpty {
                Text("\(model.text(.keptInPlace)) \(TouchLayout.Control.allCases.filter(geometry.dropped.contains).map(\.rawValue).joined(separator: " "))")
                    .font(.system(size: 11)).foregroundStyle(ShellInk.bad).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button(model.text(.resetLayout)) { controls.layout.reset(kind) }
                    .buttonStyle(ShellButtonStyle())
                    .disabled(controls.layout.isEmpty(kind))
                Button { panelLow.toggle() } label: { Image(systemName: panelLow ? "arrow.up" : "arrow.down") }
                    .buttonStyle(ShellButtonStyle())
                    .accessibilityLabel(model.text(.movePanel))
            }
            HStack(spacing: 8) {
                Button(model.text(.cancel), action: close).buttonStyle(ShellButtonStyle())
                Button(model.text(.save)) {
                    var touch = model.touch
                    touch.layout = controls.layout
                    model.setTouch(touch)
                    close()
                }
                .buttonStyle(ShellButtonStyle(prominent: true))
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .background(ShellInk.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ShellInk.line))
    }
}

/// The editor in a window of its own above the library, as the game's view is (`FrameworkEngineHost.present`): the
/// library's sheets only turn with the phone held upright, and a window whose controller asks for landscape turns the
/// screen the way the game will, whichever way the phone is held.
@MainActor
enum TouchLayoutEditorWindow {
    private static var window: UIWindow?
    /// The way the library was shown before, to turn back to: the phone is likely still held sideways when the editor closes.
    private static var before: UIInterfaceOrientationMask = .portrait

    final class Controller<Content: View>: UIHostingController<Content> {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
        override var prefersStatusBarHidden: Bool { true }
        override var prefersHomeIndicatorAutoHidden: Bool { true }
    }

    static func present(_ model: ShellHostModel) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: before = .landscapeLeft
        case .landscapeRight: before = .landscapeRight
        default: before = .portrait
        }
        let window = UIWindow(windowScene: scene)
        let editor = TouchLayoutEditor(controls: model.touch, close: dismiss).environmentObject(model)
        let controller = Controller(rootView: editor)
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        window.windowLevel = .normal + 1   // above the library's sheets
        window.makeKeyAndVisible()
        self.window = window
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
            NSLog("NXPocketApple: the layout editor stays upright: %@", error.localizedDescription)
        }
    }

    /// The library's window takes the screen back, and turns it back the way it can be shown.
    static func dismiss() {
        guard let window else { return }
        let scene = window.windowScene
        window.isHidden = true
        self.window = nil
        let library = scene?.windows.first { $0.windowLevel == .normal && !$0.isHidden }
        library?.makeKey()
        library?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: before)) { _ in }
    }
}

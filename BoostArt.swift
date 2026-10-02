import SwiftUI
import AppKit

struct BoostDial: View {
    @ObservedObject var b: Boost
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 6).padding(9)
                Circle().trim(from: 0, to: b.progress)
                    .stroke(Color.brandTeal, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(9)
                    .opacity(b.progress > 0 ? 1 : 0)
                if b.running && !reduce { Comet().padding(9) }
                core
            }
            .frame(width: 280, height: 280)
            .contentShape(Circle())
            .glassDisk()
            .background(halo)
        }
        .buttonStyle(DialPress())
        .disabled(b.running)
        .accessibilityLabel("Boost")
        .accessibilityHint("Barre la basura segura y da respiro a lo pesado de fondo")
        .help(b.running ? "Trabajando, un momento" : "Toca para hacer un Boost")
    }

    private var core: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.brandNavy, .brandTeal], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(LinearGradient(colors: [.white.opacity(0.26), .clear], startPoint: .top, endPoint: .center)).padding(3)
            if b.phase == .done {
                DoneMark(reduce: reduce).transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                SweepScene(start: reduce ? nil : b.started, stop: b.stopped, live: b.running && !reduce)
                    .clipShape(Circle())
                    .transition(.opacity)
                if b.phase == .idle {
                    Text("Boost").font(.system(size: 24, weight: .bold)).tracking(-0.5).foregroundStyle(.white)
                        .offset(y: 78).transition(.opacity)
                }
            }
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .frame(width: 224, height: 224)
        .shadow(color: Color.brandNavy.opacity(0.35), radius: 16, y: 8)
    }

    private var halo: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.brandTeal.opacity(b.running ? 0.42 : 0.26), .clear], center: .center, startRadius: 100, endRadius: 170))
            .frame(width: 340, height: 340)
            .animation(.smooth(duration: 0.8), value: b.running)
            .allowsHitTesting(false)
    }
}

private struct DialPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { DialPressBody(configuration: configuration) }
}

private struct DialPressBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : hover && enabled ? 1.02 : 1)
            .onHover { hover = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: configuration.isPressed)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hover)
    }
}

private extension View {
    @ViewBuilder func glassDisk() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

private struct Comet: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            Circle().trim(from: 0.02, to: 0.24)
                .stroke(AngularGradient(colors: [Color.brandTeal.opacity(0), Color.brandTeal], center: .center,
                                        startAngle: .degrees(7.2), endAngle: .degrees(86.4)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.radians(t * 2 * .pi))
        }
    }
}

private struct DoneMark: View {
    let reduce: Bool
    @State private var on = false
    var body: some View {
        ZStack {
            if !reduce {
                ForEach(0..<12, id: \.self) { i in
                    let a = Double(i) / 12 * 2 * .pi + 0.2
                    Image(systemName: "sparkle")
                        .font(.system(size: CGFloat(8 + (i % 3) * 5), weight: .bold))
                        .foregroundStyle(i % 3 == 0 ? Color(red: 0.98, green: 0.78, blue: 0.35) : .white)
                        .scaleEffect(on ? 1 : 0.2)
                        .offset(x: cos(a) * (on ? 128 : 30), y: sin(a) * (on ? 128 : 30))
                        .animation(.easeOut(duration: 0.8), value: on)
                        .opacity(on ? 0 : 1)
                        .animation(.easeIn(duration: 0.7).delay(0.25), value: on)
                }
            }
            Tick().trim(from: 0, to: on ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 96)
                .animation(.spring(response: 0.5, dampingFraction: 0.9).delay(0.1), value: on)
        }
        .task { on = true }
    }
}

private struct Tick: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.54))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.75))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.8, y: r.minY + r.height * 0.3))
        }
    }
}

// Every frame is a pure function of elapsed time, so the scene resumes exactly when the pane is reopened mid-run.
private struct SweepScene: View {
    let start: Date?
    let stop: Date?
    let live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !live)) { tl in
            Canvas { ctx, size in
                let e = live ? start.map { tl.date.timeIntervalSince($0) } : nil
                let s = stop.flatMap { st in start.map { st.timeIntervalSince($0) } }
                drawSweep(ctx, size.width, e, s)
            } symbols: {
                Group {
                    Image(systemName: "doc.fill").tag(0)
                    Image(systemName: "doc.text.fill").tag(1)
                    Image(systemName: "paperplane.fill").tag(2)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            }
        }
    }
}

private let sweepHz = 1.3
private let restAngle = 0.12
private let floorY = 0.74
private let spawnGap = 0.07

private struct Flight { let s: Double, d: Double, p0: CGPoint, c: CGPoint, p1: CGPoint, kind: Int, rest: Double }

private let mess: [(CGPoint, Double, Int)] = [(CGPoint(x: 0.1, y: 0.712), -0.4, 0), (CGPoint(x: 0.17, y: 0.722), 0, 3), (CGPoint(x: 0.235, y: 0.718), .pi / 4 + 0.1, 2)]

private func rnd(_ i: Int, _ k: Int) -> Double {
    let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
    return x - x.rounded(.down)
}

private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

private func broomAngle(_ e: Double, _ stop: Double?) -> Double {
    let active = -0.02 + 0.28 * sin(2 * .pi * sweepHz * e)
    let a = restAngle + (active - restAngle) * smooth(0, 0.35, e)
    return a + (restAngle - a) * (stop.map { smooth($0, $0 + 0.5, e) } ?? 0)
}

private func broomFoot(_ a: Double) -> CGPoint { CGPoint(x: 0.28 + 0.52 * sin(a), y: 0.22 + 0.52 * cos(a)) }

private func binMouth(_ i: Int) -> CGPoint { CGPoint(x: 0.64 + (rnd(i, 1) - 0.5) * 0.1, y: 0.53) }

private func arc(from p0: CGPoint, to p1: CGPoint, lift: Double) -> CGPoint {
    CGPoint(x: (p0.x + p1.x) / 2 - 0.03, y: min(p0.y, p1.y) - lift)
}

private func flight(_ i: Int) -> Flight? {
    let s = Double(i) * spawnGap
    let target = binMouth(i)
    if i % 7 == 3 {
        let p0 = CGPoint(x: -0.08, y: 0.18 + 0.16 * rnd(i, 2))
        return Flight(s: s, d: 1.05 + 0.2 * rnd(i, 3), p0: p0, c: CGPoint(x: 0.36, y: p0.y - 0.1), p1: target, kind: 2, rest: 0)
    }
    guard cos(2 * .pi * sweepHz * s) > 0.3 else { return nil }
    let foot = broomFoot(broomAngle(s, nil))
    let p0 = CGPoint(x: foot.x + 0.04, y: floorY - 0.02)
    return Flight(s: s, d: 0.75 + 0.3 * rnd(i, 5), p0: p0, c: arc(from: p0, to: target, lift: 0.24 + 0.14 * rnd(i, 4)), p1: target,
                  kind: i % 3 == 0 ? 3 : i % 2, rest: rnd(i, 6) * 6.28)
}

private func messFlight(_ k: Int) -> Flight {
    let (p0, rot, kind) = mess[k]
    let target = binMouth(100 + k)
    return Flight(s: 0.1 + 0.14 * Double(k), d: 0.8, p0: p0, c: arc(from: p0, to: target, lift: 0.22), p1: target, kind: kind, rest: rot)
}

private func point(_ f: Flight, _ u: Double) -> CGPoint {
    let v = 1 - u
    return CGPoint(x: v * v * f.p0.x + 2 * v * u * f.c.x + u * u * f.p1.x, y: v * v * f.p0.y + 2 * v * u * f.c.y + u * u * f.p1.y)
}

private func heading(_ f: Flight, _ u: Double) -> Double {
    atan2(2 * (1 - u) * (f.c.y - f.p0.y) + 2 * u * (f.p1.y - f.c.y), 2 * (1 - u) * (f.c.x - f.p0.x) + 2 * u * (f.p1.x - f.c.x))
}

private func drawSweep(_ ctx: GraphicsContext, _ S: CGFloat, _ e: Double?, _ stop: Double?) {
    func oval(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> Path {
        Path(ellipseIn: CGRect(x: (cx - w / 2) * S, y: (cy - h / 2) * S, width: w * S, height: h * S))
    }
    func item(_ kind: Int, _ p: CGPoint, _ rot: Double, _ scale: Double) {
        var c = ctx
        c.translateBy(x: p.x * S, y: p.y * S)
        c.rotate(by: .radians(rot))
        c.scaleBy(x: scale, y: scale)
        if kind == 3 {
            let r = 0.026 * S
            var ball = Path()
            for j in 0..<9 {
                let t = Double(j) / 9 * 2 * .pi, rr = r * (0.78 + 0.34 * rnd(j, 11))
                let v = CGPoint(x: cos(t) * rr, y: sin(t) * rr)
                j == 0 ? ball.move(to: v) : ball.addLine(to: v)
            }
            ball.closeSubpath()
            c.fill(ball, with: .color(.white.opacity(0.95)))
            var crease = Path()
            crease.move(to: CGPoint(x: -r * 0.6, y: r * 0.1))
            crease.addLine(to: CGPoint(x: -r * 0.1, y: -r * 0.15))
            crease.move(to: CGPoint(x: r * 0.05, y: r * 0.45))
            crease.addLine(to: CGPoint(x: r * 0.4, y: -r * 0.05))
            c.stroke(crease, with: .color(Color.brandNavy.opacity(0.22)), lineWidth: 0.9)
        } else if let sym = c.resolveSymbol(id: kind) {
            c.draw(sym, at: .zero)
        }
    }

    let a = e.map { broomAngle($0, stop) } ?? restAngle
    let foot = broomFoot(a)
    ctx.fill(oval(0.64, floorY + 0.006, 0.3, 0.035), with: .color(.black.opacity(0.2)))
    ctx.fill(oval(foot.x, floorY + 0.004, 0.16, 0.028), with: .color(.black.opacity(0.16)))

    if let e {
        let gap = 0.045, limit = min(e, stop ?? e)
        var i = Int(max(0, e - 0.6) / gap)
        while Double(i) * gap <= limit {
            let s = Double(i) * gap, u = (e - s) / 0.6
            if u >= 0, u <= 1, cos(2 * .pi * sweepHz * s) > 0 {
                let f = broomFoot(broomAngle(s, nil))
                let r = 0.016 + 0.06 * u
                ctx.fill(oval(f.x - 0.05 * u - 0.02 * rnd(i, 7), floorY - 0.01 - 0.08 * u * (0.6 + 0.4 * rnd(i, 8)), r, r), with: .color(.white.opacity(0.3 * (1 - u))))
            }
            i += 1
        }
    }

    drawBroom(ctx, S, a)

    var recent: Double?
    func fly(_ f: Flight, _ i: Int, _ e: Double) {
        let u = (e - f.s) / f.d
        if u > 1 { recent = min(recent ?? .infinity, e - f.s - f.d); return }
        guard u >= 0 else { return }
        var p = point(f, u)
        let rot: Double
        if f.kind == 2 {
            p.y += sin(u * .pi * 4) * 0.012
            rot = heading(f, u) + .pi / 4
        } else {
            rot = f.rest + (rnd(i, 9) - 0.5) * 10 * u
        }
        let grow = f.kind == 2 || i >= 100 ? 1 : 0.4 + 0.6 * smooth(0, 0.15, u)
        item(f.kind, p, rot, grow * (1 - 0.3 * smooth(0.75, 1, u)) * (f.kind == 2 ? 1.1 : 1))
    }

    for k in mess.indices {
        let f = messFlight(k)
        if let e, e >= f.s { fly(f, 100 + k, e) } else { item(f.kind, f.p0, f.rest, 1) }
    }
    if let e {
        var i = Int(max(0, e - 1.9) / spawnGap)
        while Double(i) * spawnGap <= min(e, stop ?? e) {
            if let f = flight(i) { fly(f, i, e) }
            i += 1
        }
    }

    var lid = 0.0
    if let e {
        lid = 1.1 * (1 - exp(-9 * e) * cos(12 * e))
        if let r = recent, r < 0.5 { lid += 0.14 * exp(-8 * r) * sin(30 * r) }
        if let st = stop, e > st + 1.3 {
            let t = e - st - 1.3
            lid = 1.1 * exp(-7 * t) * abs(cos(11 * t))
        }
    }
    let squash = recent.map { 0.05 * exp(-14 * $0) } ?? 0
    drawBin(ctx, S, lid, squash)
}

private func drawBroom(_ ctx: GraphicsContext, _ S: CGFloat, _ a: Double) {
    var c = ctx
    c.translateBy(x: 0.28 * S, y: 0.22 * S)
    c.rotate(by: .radians(-a))
    let straw = Color(red: 0.98, green: 0.77, blue: 0.33), strawDark = Color(red: 0.86, green: 0.58, blue: 0.2)
    var handle = Path()
    handle.move(to: .zero)
    handle.addLine(to: CGPoint(x: 0, y: 0.38 * S))
    c.stroke(handle, with: .color(Color(red: 0.93, green: 0.78, blue: 0.6)), style: StrokeStyle(lineWidth: 0.026 * S, lineCap: .round))

    let top = 0.385 * S, bot = 0.52 * S, tw = 0.04 * S, bw = 0.09 * S
    var head = Path()
    head.move(to: CGPoint(x: -tw, y: top))
    head.addLine(to: CGPoint(x: tw, y: top))
    head.addLine(to: CGPoint(x: bw, y: bot))
    head.addQuadCurve(to: CGPoint(x: -bw, y: bot), control: CGPoint(x: 0, y: bot + 0.015 * S))
    head.closeSubpath()
    c.fill(head, with: .linearGradient(Gradient(colors: [strawDark, straw]), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bot)))
    for k in -2...2 {
        var strand = Path()
        strand.move(to: CGPoint(x: Double(k) * 0.016 * S, y: top + 0.02 * S))
        strand.addLine(to: CGPoint(x: Double(k) * 0.036 * S, y: bot - 0.005 * S))
        c.stroke(strand, with: .color(strawDark.opacity(0.55)), lineWidth: 0.006 * S)
    }
    c.fill(Path(roundedRect: CGRect(x: -0.048 * S, y: 0.365 * S, width: 0.096 * S, height: 0.035 * S), cornerRadius: 0.01 * S), with: .color(.white))
    c.fill(Path(CGRect(x: -0.048 * S, y: 0.378 * S, width: 0.096 * S, height: 0.008 * S)), with: .color(Color.brandNavy.opacity(0.35)))
}

private func drawBin(_ ctx: GraphicsContext, _ S: CGFloat, _ lid: Double, _ squash: Double) {
    var c = ctx
    let cx = 0.64 * S, bottom = floorY * S, top = 0.455 * S, tw = 0.125 * S, bw = 0.1 * S
    c.translateBy(x: cx, y: bottom)
    c.scaleBy(x: 1 + squash * 0.6, y: 1 - squash)
    c.translateBy(x: -cx, y: -bottom)

    let r = 0.03 * S
    var body = Path()
    body.move(to: CGPoint(x: cx - tw, y: top))
    body.addLine(to: CGPoint(x: cx + tw, y: top))
    body.addLine(to: CGPoint(x: cx + bw, y: bottom - r))
    body.addQuadCurve(to: CGPoint(x: cx + bw - r, y: bottom), control: CGPoint(x: cx + bw, y: bottom))
    body.addLine(to: CGPoint(x: cx - bw + r, y: bottom))
    body.addQuadCurve(to: CGPoint(x: cx - bw, y: bottom - r), control: CGPoint(x: cx - bw, y: bottom))
    body.closeSubpath()
    c.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.97), .white.opacity(0.8)]), startPoint: CGPoint(x: cx, y: top), endPoint: CGPoint(x: cx, y: bottom)))
    for k in [-1.0, 0, 1] {
        var rib = Path()
        rib.move(to: CGPoint(x: cx + k * 0.055 * S, y: top + 0.05 * S))
        rib.addLine(to: CGPoint(x: cx + k * 0.045 * S, y: bottom - 0.045 * S))
        c.stroke(rib, with: .color(Color.brandNavy.opacity(0.22)), style: StrokeStyle(lineWidth: 0.018 * S, lineCap: .round))
    }

    var l = c
    l.translateBy(x: cx + tw + 0.012 * S, y: top)
    l.rotate(by: .radians(lid))
    let w = 2 * tw + 0.024 * S
    l.fill(Path(roundedRect: CGRect(x: -w, y: -0.035 * S, width: w, height: 0.035 * S), cornerRadius: 0.012 * S), with: .color(.white))
    l.fill(Path(CGRect(x: -w + 0.01 * S, y: -0.008 * S, width: w - 0.02 * S, height: 0.008 * S)), with: .color(Color.brandNavy.opacity(0.15)))
    l.stroke(Path(roundedRect: CGRect(x: -w / 2 - 0.04 * S, y: -0.062 * S, width: 0.08 * S, height: 0.034 * S), cornerRadius: 0.012 * S),
             with: .color(.white), lineWidth: 0.014 * S)
}

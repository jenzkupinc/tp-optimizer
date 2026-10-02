import SwiftUI
import AppKit

struct FireBand: View {
    let heat: Double
    let label: String
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.05, blue: 0.09), Color(red: 0.17, green: 0.05, blue: 0.04)], startPoint: .top, endPoint: .bottom))
            LinearGradient(colors: [Color(red: 1, green: 0.4, blue: 0.08).opacity(0.4 * min(heat, 1)), .clear], startPoint: .bottom, endPoint: .center)
            Embers(heat: heat, live: live && !still)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 3)
                .background(.black.opacity(0.62), in: Capsule()).padding(8)
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

private struct Embers: NSViewRepresentable {
    let heat: Double
    let live: Bool

    func makeNSView(context: Context) -> EmberView { EmberView() }
    func updateNSView(_ view: EmberView, context: Context) { view.apply(heat: heat, live: live) }
}

private final class EmberView: NSView {
    private let emitter = CAEmitterLayer()

    private static let sprite: CGImage? = {
        let w = 40, h = 96
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1]) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) * 0.36)
        ctx.scaleBy(x: 1, y: 2.3)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: CGFloat(w) / 2, options: [])
        return ctx.makeImage()
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        emitter.emitterShape = .line
        emitter.renderMode = .additive
        emitter.emitterCells = [
            cell("flame", rate: 80, life: 0.9, speed: 38, scale: 0.7, color: NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 0.95), greenSpeed: -0.55, blueSpeed: -0.4),
            cell("spark", rate: 10, life: 1.8, speed: 70, scale: 0.12, color: NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), greenSpeed: -0.2, blueSpeed: -0.3),
        ]
        layer?.addSublayer(emitter)
    }

    required init?(coder: NSCoder) { nil }

    private func cell(_ name: String, rate: Float, life: Float, speed: CGFloat, scale: CGFloat, color: NSColor, greenSpeed: Float, blueSpeed: Float) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.name = name
        c.contents = EmberView.sprite
        c.birthRate = rate
        c.lifetime = life
        c.lifetimeRange = life * 0.35
        c.velocity = speed
        c.velocityRange = speed * 0.4
        c.emissionLongitude = .pi / 2
        c.emissionRange = .pi / 14
        c.scale = scale
        c.scaleRange = scale * 0.4
        c.scaleSpeed = -scale * 0.3
        c.alphaSpeed = -0.8
        c.color = color.cgColor
        c.greenSpeed = greenSpeed
        c.blueSpeed = blueSpeed
        c.redSpeed = -0.05
        return c
    }

    override func layout() {
        super.layout()
        emitter.frame = bounds
        emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: 0)
    }

    func apply(heat: Double, live: Bool) {
        let h = Float(min(max(heat, 0.15), 1.2))
        let lift = 0.3 + 0.7 * min(h, 1)
        emitter.birthRate = live ? 1 : 0
        emitter.setValue(80 * lift, forKeyPath: "emitterCells.flame.birthRate")
        emitter.setValue(38 * lift, forKeyPath: "emitterCells.flame.velocity")
        emitter.setValue(0.4 + 0.4 * min(h, 1), forKeyPath: "emitterCells.flame.scale")
        emitter.setValue(4 + 14 * h, forKeyPath: "emitterCells.spark.birthRate")
    }
}

struct FireButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 13).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.1), Color(red: 0.86, green: 0.18, blue: 0.1)], startPoint: .top, endPoint: .bottom))
                .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.22)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

import SwiftUI

/// Rotary jog wheel. Every `stepDegrees` of rotation emits one step (+1 clockwise, -1 counter-clockwise).
struct JogWheelView: View {
    var stepDegrees: Double = 12
    let onStep: (Int) -> Void

    @State private var lastAngle: Double?
    @State private var accumulated: Double = 0
    @State private var rotation: Double = 0
    @State private var touching = false

    init(stepDegrees: Double = 12, onStep: @escaping (Int) -> Void) {
        self.stepDegrees = stepDegrees
        self.onStep = onStep
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
                Circle()
                    .strokeBorder(touching ? Theme.accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 2)

                ZStack {
                    ForEach(0..<48, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(i % 4 == 0 ? 0.55 : 0.18))
                            .frame(width: 2, height: i % 4 == 0 ? size * 0.05 : size * 0.025)
                            .offset(y: -size / 2 + size * 0.06)
                            .rotationEffect(.degrees(Double(i) * 7.5))
                    }
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: size * 0.07, height: size * 0.07)
                        .offset(y: -size / 2 + size * 0.17)
                }
                .rotationEffect(.degrees(rotation))

                Circle()
                    .fill(Color(white: 0.07))
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }
            .frame(width: size, height: size)
            .position(center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touching = true
                        let dx = Double(value.location.x - center.x)
                        let dy = Double(value.location.y - center.y)
                        // Ignore the dead zone in the middle – angle is unstable there.
                        guard (dx * dx + dy * dy).squareRoot() > Double(size) * 0.12 else {
                            lastAngle = nil
                            return
                        }
                        let angle = atan2(dy, dx) * 180 / Double.pi
                        if let last = lastAngle {
                            var delta = angle - last
                            if delta > 180 { delta -= 360 }
                            if delta < -180 { delta += 360 }
                            rotation += delta
                            accumulated += delta
                            var steps = 0
                            while accumulated >= stepDegrees { accumulated -= stepDegrees; steps += 1 }
                            while accumulated <= -stepDegrees { accumulated += stepDegrees; steps -= 1 }
                            if steps != 0 { onStep(steps) }
                        }
                        lastAngle = angle
                    }
                    .onEnded { _ in
                        touching = false
                        lastAngle = nil
                        accumulated = 0
                    }
            )
        }
    }
}

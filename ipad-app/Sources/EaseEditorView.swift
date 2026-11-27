import SwiftUI

struct EasePreset: Codable, Hashable {
    let name: String
    let curve: [Double]
}

/// Cubic-bezier easing editor (works with finger or Apple Pencil).
/// "Apliko" sends the curve to the PC agent, which applies it to the
/// selected keyframes in After Effects.
struct EaseEditorView: View {
    let enabled: Bool
    let onApply: ([Double]) -> Void

    @State private var p1 = CGPoint(x: 0.33, y: 0.0)
    @State private var p2 = CGPoint(x: 0.67, y: 1.0)
    @State private var activeHandle: Int?
    @AppStorage("usbdeck.customEases") private var customData: Data = Data()

    init(enabled: Bool, onApply: @escaping ([Double]) -> Void) {
        self.enabled = enabled
        self.onApply = onApply
    }

    static let builtIn: [EasePreset] = [
        EasePreset(name: "Easy Ease", curve: [0.33, 0.0, 0.67, 1.0]),
        EasePreset(name: "Smooth", curve: [0.4, 0.0, 0.2, 1.0]),
        EasePreset(name: "Ease In", curve: [0.42, 0.0, 1.0, 1.0]),
        EasePreset(name: "Ease Out", curve: [0.0, 0.0, 0.58, 1.0]),
        EasePreset(name: "Expo Out", curve: [0.16, 1.0, 0.3, 1.0]),
        EasePreset(name: "Expo In-Out", curve: [0.87, 0.0, 0.13, 1.0]),
        EasePreset(name: "Back Out", curve: [0.34, 1.56, 0.64, 1.0]),
        EasePreset(name: "Snap", curve: [0.7, 0.0, 0.1, 1.0]),
        EasePreset(name: "Linear", curve: [0.0, 0.0, 1.0, 1.0]),
    ]

    private var customPresets: [EasePreset] {
        (try? JSONDecoder().decode([EasePreset].self, from: customData)) ?? []
    }

    private var curve: [Double] {
        [p1.x, p1.y, p2.x, p2.y].map { (Double($0) * 100).rounded() / 100 }
    }

    var body: some View {
        VStack(spacing: 12) {
            CurveCanvas(p1: $p1, p2: $p2, activeHandle: $activeHandle)
                .aspectRatio(1, contentMode: .fit)

            EasePreview(curve: curve)
                .frame(height: 22)

            Text(String(format: "cubic-bezier(%.2f, %.2f, %.2f, %.2f)", curve[0], curve[1], curve[2], curve[3]))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textDim)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                ForEach(Self.builtIn + customPresets, id: \.self) { preset in
                    Button {
                        load(preset)
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(isCurrent(preset) ? Theme.accent : Theme.raised))
                            .foregroundColor(.white)
                    }
                    .contextMenu {
                        if customPresets.contains(preset) {
                            Button(role: .destructive) { delete(preset) } label: { Label("Fshi", systemImage: "trash") }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button { saveCustom() } label: {
                    Label("Ruaj", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                }
                Button { onApply(curve) } label: {
                    Label("Apliko te keyframe-t", systemImage: "wand.and.stars")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(enabled ? Theme.accent : Theme.raised))
                }
                .disabled(!enabled)
                .layoutPriority(1)
            }
            .foregroundColor(.white)
        }
    }

    private func isCurrent(_ preset: EasePreset) -> Bool {
        zip(preset.curve, curve).allSatisfy { abs($0 - $1) < 0.005 }
    }

    private func load(_ preset: EasePreset) {
        guard preset.curve.count == 4 else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            p1 = CGPoint(x: preset.curve[0], y: preset.curve[1])
            p2 = CGPoint(x: preset.curve[2], y: preset.curve[3])
        }
    }

    private func saveCustom() {
        var list = customPresets
        list.append(EasePreset(name: "Imja \(list.count + 1)", curve: curve))
        if let data = try? JSONEncoder().encode(list) { customData = data }
    }

    private func delete(_ preset: EasePreset) {
        let list = customPresets.filter { $0 != preset }
        if let data = try? JSONEncoder().encode(list) { customData = data }
    }
}

// MARK: - Curve canvas

private struct CurveCanvas: View {
    @Binding var p1: CGPoint
    @Binding var p2: CGPoint
    @Binding var activeHandle: Int?

    private let yMin: CGFloat = -0.35
    private let yMax: CGFloat = 1.35
    private let inset: CGFloat = 16

    init(p1: Binding<CGPoint>, p2: Binding<CGPoint>, activeHandle: Binding<Int?>) {
        self._p1 = p1
        self._p2 = p2
        self._activeHandle = activeHandle
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            let h = geo.size.height - inset * 2
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised)

                Path { path in
                    for i in 0...4 {
                        let x = inset + CGFloat(i) / 4 * w
                        path.move(to: CGPoint(x: x, y: inset))
                        path.addLine(to: CGPoint(x: x, y: inset + h))
                    }
                }
                .stroke(Color.white.opacity(0.05), lineWidth: 1)

                Path { path in
                    for v in [CGFloat(0), CGFloat(1)] {
                        path.move(to: point(CGPoint(x: 0, y: v), w, h))
                        path.addLine(to: point(CGPoint(x: 1, y: v), w, h))
                    }
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Path { path in
                    path.move(to: point(CGPoint(x: 0, y: 0), w, h))
                    path.addLine(to: point(p1, w, h))
                    path.move(to: point(CGPoint(x: 1, y: 1), w, h))
                    path.addLine(to: point(p2, w, h))
                }
                .stroke(Theme.accent.opacity(0.7), lineWidth: 1.5)

                Path { path in
                    path.move(to: point(CGPoint(x: 0, y: 0), w, h))
                    path.addCurve(to: point(CGPoint(x: 1, y: 1), w, h),
                                  control1: point(p1, w, h),
                                  control2: point(p2, w, h))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                handle(at: point(p1, w, h), active: activeHandle == 1)
                handle(at: point(p2, w, h), active: activeHandle == 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if activeHandle == nil {
                            let d1 = distance(value.startLocation, point(p1, w, h))
                            let d2 = distance(value.startLocation, point(p2, w, h))
                            activeHandle = d1 <= d2 ? 1 : 2
                        }
                        let x = min(max((value.location.x - inset) / w, 0), 1)
                        let y = min(max(yMax - (value.location.y - inset) / h * (yMax - yMin), yMin), yMax)
                        if activeHandle == 1 { p1 = CGPoint(x: x, y: y) } else { p2 = CGPoint(x: x, y: y) }
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
    }

    private func point(_ p: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        CGPoint(x: inset + p.x * w, y: inset + (yMax - p.y) / (yMax - yMin) * h)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func handle(at p: CGPoint, active: Bool) -> some View {
        Circle()
            .fill(active ? Color.white : Theme.accent)
            .frame(width: active ? 26 : 20, height: active ? 26 : 20)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
            .position(p)
    }
}

// MARK: - Live preview

private struct EasePreview: View {
    let curve: [Double]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = min(t.truncatingRemainder(dividingBy: 1.6) / 1.1, 1.0)
            let progress = EasePreview.value(at: phase, curve)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: geo.size.height, height: geo.size.height)
                        .offset(x: CGFloat(progress) * (geo.size.width - geo.size.height))
                }
            }
        }
    }

    static func value(at t: Double, _ c: [Double]) -> Double {
        guard c.count == 4 else { return t }
        let x1 = c[0], y1 = c[1], x2 = c[2], y2 = c[3]
        func bx(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u }
        func by(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<32 {
            u = (lo + hi) / 2
            if bx(u) < t { lo = u } else { hi = u }
        }
        return by(u)
    }
}

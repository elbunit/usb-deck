import SwiftUI
import UIKit

/// Live video scopes computed on the PC from a screen region (e.g. Program Monitor).
final class ScopesModel: ObservableObject {
    @Published var waveform: UIImage?
    @Published var parade: UIImage?
    @Published var vector: UIImage?
    @Published var hist: ScopesHistMessage?
    @Published var sources: [ScreenSource] = []
    @Published var current = "region"
    @Published var fps = 0
    private var count = 0
    private var stamp = Date()

    func set(kind: Int, image: UIImage) {
        switch kind {
        case 2: waveform = image
        case 3: parade = image
        default:
            vector = image
            count += 1
            if Date().timeIntervalSince(stamp) >= 1 {
                fps = count
                count = 0
                stamp = Date()
            }
        }
    }
}

struct ScopesView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var model: ScopesModel
    @AppStorage("usbdeck.scopesSource") private var savedSource = "region"
    @State private var focus: Int?          // nil = 2x2 grid, else one big scope

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Scopes").font(.system(size: 22, weight: .bold))
                Menu {
                    ForEach(model.sources) { s in
                        Button("\(s.name)  \(s.detail ?? "")") {
                            savedSource = s.id
                            model.current = s.id
                            conn.send(["type": "scopes_start", "source": s.id])
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.sources.first { $0.id == model.current }?.name ?? "Burimi")
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.raised))
                }
                Button {
                    conn.send(["type": "scopes_pick_region"])
                } label: {
                    Label("Zgjidh zonën në PC", systemImage: "viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                }
                Spacer()
                Text("\(model.fps) fps").font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }

            if let f = focus {
                scope(f).onTapGesture { withAnimation { focus = nil } }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        scope(0).onTapGesture { withAnimation { focus = 0 } }
                        scope(1).onTapGesture { withAnimation { focus = 1 } }
                    }
                    HStack(spacing: 10) {
                        scope(2).onTapGesture { withAnimation { focus = 2 } }
                        scope(3).onTapGesture { withAnimation { focus = 3 } }
                    }
                }
            }
        }
        .padding(16)
        .foregroundColor(.white)
        .onAppear { conn.send(["type": "scopes_start", "source": savedSource]) }
        .onDisappear { conn.send(["type": "scopes_stop"]) }
    }

    @ViewBuilder
    private func scope(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(["Waveform (Luma)", "RGB Parade", "Vectorscope", "Histogram"][i])
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.textDim)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                switch i {
                case 0: WaveGraticule(image: model.waveform, sections: 1)
                case 1: WaveGraticule(image: model.parade, sections: 3)
                case 2: VectorGraticule(image: model.vector)
                default: HistogramView(hist: model.hist)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct WaveGraticule: View {
    let image: UIImage?
    let sections: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                if let img = image {
                    Image(uiImage: img).resizable().interpolation(.medium).frame(width: w, height: h)
                }
                Path { p in
                    for i in 0...10 {
                        let y = h - CGFloat(i) / 10 * h
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    if sections > 1 {
                        for s in 1..<sections {
                            let x = w * CGFloat(s) / CGFloat(sections)
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: h))
                        }
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                ForEach([100, 75, 50, 25, 0], id: \.self) { v in
                    Text("\(v)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45))
                        .position(x: 12, y: max(7, min(h - 7, h - CGFloat(v) / 100 * h)))
                }
            }
        }
    }
}

private struct VectorGraticule: View {
    let image: UIImage?

    /// 75% colour-bar targets in Rec.709 Cb/Cr (x = Cb, y = -Cr), normalised 0..1.
    private static let targets: [(String, CGPoint)] = {
        func pt(_ r: Double, _ g: Double, _ b: Double) -> CGPoint {
            let cb = -0.1146 * r - 0.3854 * g + 0.5 * b
            let cr = 0.5 * r - 0.4542 * g - 0.0458 * b
            return CGPoint(x: (128 + cb) / 256, y: (128 - cr) / 256)
        }
        let v = 191.25
        return [("R", pt(v, 0, 0)), ("Mg", pt(v, 0, v)), ("B", pt(0, 0, v)),
                ("Cy", pt(0, v, v)), ("G", pt(0, v, 0)), ("Yl", pt(v, v, 0))]
    }()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ox = (geo.size.width - side) / 2, oy = (geo.size.height - side) / 2
            ZStack(alignment: .topLeading) {
                if let img = image {
                    Image(uiImage: img).resizable().interpolation(.medium)
                        .frame(width: side, height: side)
                        .offset(x: ox, y: oy)
                }
                Path { p in
                    let c = CGPoint(x: ox + side / 2, y: oy + side / 2)
                    p.addEllipse(in: CGRect(x: ox + side * 0.02, y: oy + side * 0.02, width: side * 0.96, height: side * 0.96))
                    p.move(to: CGPoint(x: c.x - side / 2, y: c.y)); p.addLine(to: CGPoint(x: c.x + side / 2, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - side / 2)); p.addLine(to: CGPoint(x: c.x, y: c.y + side / 2))
                }
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                // Skin-tone line (≈123°)
                Path { p in
                    let c = CGPoint(x: ox + side / 2, y: oy + side / 2)
                    let a = 123.0 * Double.pi / 180
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * side * 0.48, y: c.y - CGFloat(sin(a)) * side * 0.48))
                }
                .stroke(Color(red: 1, green: 0.75, blue: 0.55).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ForEach(Self.targets, id: \.0) { t in
                    ZStack {
                        Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1)
                            .frame(width: side * 0.045, height: side * 0.045)
                        Text(t.0).font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.6))
                            .offset(x: side * 0.045, y: -side * 0.035)
                    }
                    .position(x: ox + t.1.x * side, y: oy + t.1.y * side)
                }
            }
        }
    }
}

private struct HistogramView: View {
    let hist: ScopesHistMessage?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if let hst = hist {
                    area(hst.y, w, h).fill(Color.white.opacity(0.22))
                    line(hst.r, w, h).stroke(Color(red: 1, green: 0.3, blue: 0.3), lineWidth: 1.4)
                    line(hst.g, w, h).stroke(Color(red: 0.3, green: 1, blue: 0.4), lineWidth: 1.4)
                    line(hst.b, w, h).stroke(Color(red: 0.35, green: 0.55, blue: 1), lineWidth: 1.4)
                }
                Path { p in
                    for i in 1..<4 {
                        let x = w * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    }
                }
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
    }

    private func line(_ v: [Double], _ w: CGFloat, _ h: CGFloat) -> Path {
        Path { p in
            guard v.count > 1 else { return }
            for (i, val) in v.enumerated() {
                let pt = CGPoint(x: w * CGFloat(i) / CGFloat(v.count - 1), y: h - CGFloat(val) * (h - 6))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func area(_ v: [Double], _ w: CGFloat, _ h: CGFloat) -> Path {
        var p = line(v, w, h)
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

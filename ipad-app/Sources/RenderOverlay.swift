import AVFoundation
import SwiftUI
import UIKit

/// Full-screen, impossible-to-miss "render finished" celebration:
/// white flash -> animated aurora background -> confetti cannons + rain ->
/// a check mark that draws itself inside a glowing badge with shockwaves ->
/// staggered title + a synthesized fanfare. Repeats a reminder burst every 20 s
/// (3x) in case you're away from the desk.
struct RenderDoneOverlay: View {
    let event: RenderEvent
    let onReveal: () -> Void
    let onClose: () -> Void

    @State private var flash = 1.0
    @State private var badgeIn = false
    @State private var checkTrim: CGFloat = 0
    @State private var shock = false
    @State private var glow = false
    @State private var lettersIn = 0
    @State private var detailsIn = false
    @State private var burst = 0
    @State private var spin = false
    @State private var previousBrightness: CGFloat = 0.8
    @State private var reminders = 0
    private let reminderTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private let title = Array("RENDER-I PËRFUNDOI")

    init(event: RenderEvent, onReveal: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.event = event
        self.onReveal = onReveal
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            aurora
            ConfettiView(burst: burst).allowsHitTesting(false)

            VStack(spacing: 26) {
                badge
                titleView
                Text(event.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
                    .opacity(detailsIn ? 1 : 0)
                    .offset(y: detailsIn ? 0 : 20)

                HStack(spacing: 14) {
                    if let size = event.size { infoChip("internaldrive.fill", size) }
                    if let duration = event.duration { infoChip("timer", duration) }
                    if let finished = event.finished { infoChip("clock.fill", finished) }
                }
                .opacity(detailsIn ? 1 : 0)
                .offset(y: detailsIn ? 0 : 24)

                HStack(spacing: 14) {
                    if !event.path.isEmpty {
                        Button(action: onReveal) {
                            Label("Hap dosjen në PC", systemImage: "folder.fill")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 24).padding(.vertical, 14)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                                .foregroundColor(.white)
                        }
                    }
                    Button(action: onClose) {
                        Text("OK")
                            .font(.system(size: 18, weight: .heavy))
                            .padding(.horizontal, 48).padding(.vertical, 14)
                            .background(Capsule().fill(Color.white))
                            .foregroundColor(Color(red: 0.03, green: 0.32, blue: 0.22))
                            .shadow(color: .white.opacity(glow ? 0.7 : 0.2), radius: glow ? 18 : 6)
                    }
                }
                .padding(.top, 6)
                .opacity(detailsIn ? 1 : 0)
            }

            Color.white.opacity(flash).ignoresSafeArea().allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onAppear(perform: start)
        .onDisappear { UIScreen.main.brightness = previousBrightness }
        .onReceive(reminderTimer) { _ in
            guard reminders < 3 else { return }
            reminders += 1
            burst += 1
            shock = false
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 1.6)) { shock = true } }
            Fanfare.shared.play(short: true)
        }
    }

    // MARK: pieces

    private var aurora: some View {
        ZStack {
            Color(red: 0.01, green: 0.09, blue: 0.07)
            AngularGradient(colors: [Color(red: 0.0, green: 0.85, blue: 0.55), Color(red: 0.0, green: 0.55, blue: 0.9),
                                     Color(red: 0.45, green: 0.3, blue: 1.0), Color(red: 0.0, green: 0.85, blue: 0.55)],
                            center: .center)
                .scaleEffect(2.2)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .blur(radius: 60)
                .opacity(0.75)
                .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: spin)
            RadialGradient(colors: [.clear, Color.black.opacity(0.65)], center: .center, startRadius: 150, endRadius: 900)
        }
        .ignoresSafeArea()
    }

    private var badge: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 4)
                    .frame(width: 190, height: 190)
                    .scaleEffect(shock ? 2.6 + CGFloat(i) * 0.7 : 1)
                    .opacity(shock ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).delay(Double(i) * 0.18), value: shock)
            }
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.25, green: 1, blue: 0.7), Color(red: 0, green: 0.6, blue: 0.42)],
                                     center: .topLeading, startRadius: 10, endRadius: 200))
                .frame(width: 190, height: 190)
                .shadow(color: Color(red: 0.2, green: 1, blue: 0.7).opacity(glow ? 0.9 : 0.35), radius: glow ? 60 : 25)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 3))
            CheckShape()
                .trim(from: 0, to: checkTrim)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                .frame(width: 92, height: 72)
                .offset(x: 3, y: 2)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .scaleEffect(badgeIn ? 1 : 0.05)
        .rotationEffect(.degrees(badgeIn ? 0 : -120))
    }

    private var titleView: some View {
        HStack(spacing: 0) {
            ForEach(title.indices, id: \.self) { i in
                Text(String(title[i]))
                    .font(.system(size: 54, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: Color(red: 0.2, green: 1, blue: 0.75).opacity(0.8), radius: glow ? 22 : 8)
                    .opacity(i < lettersIn ? 1 : 0)
                    .scaleEffect(i < lettersIn ? 1 : 2.2)
                    .offset(y: i < lettersIn ? 0 : -30)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: lettersIn)
            }
        }
        .minimumScaleFactor(0.5)
        .lineLimit(1)
    }

    private func infoChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Symbols.valid(symbol) ?? "circle.fill")
            Text(text)
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.28)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .foregroundColor(.white)
    }

    // MARK: choreography

    private func start() {
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 1.0
        spin = true
        withAnimation(.easeOut(duration: 0.6)) { flash = 0 }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.55).delay(0.1)) { badgeIn = true }
        withAnimation(.easeOut(duration: 1.4).delay(0.25)) { shock = true }
        withAnimation(.easeInOut(duration: 0.45).delay(0.45)) { checkTrim = 1 }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.8)) { glow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { burst += 1 }
        for i in 0...title.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 + Double(i) * 0.04) { lettersIn = i }
        }
        withAnimation(.easeOut(duration: 0.5).delay(1.4)) { detailsIn = true }
        Fanfare.shared.play(short: false)
    }
}

/// The check mark path (drawn with .trim for the "writing" effect).
private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: - Confetti (CAEmitterLayer)

private struct ConfettiView: UIViewRepresentable {
    let burst: Int

    func makeUIView(context: Context) -> ConfettiHost { ConfettiHost() }

    func updateUIView(_ view: ConfettiHost, context: Context) {
        if burst != view.lastBurst {
            view.lastBurst = burst
            view.fire(big: burst <= 1)
        }
    }
}

final class ConfettiHost: UIView {
    var lastBurst = 0
    private static let colors: [UIColor] = [
        UIColor(red: 0.2, green: 1, blue: 0.7, alpha: 1), UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1),
        UIColor(red: 1, green: 0.35, blue: 0.5, alpha: 1), UIColor(red: 0.35, green: 0.6, blue: 1, alpha: 1),
        UIColor(red: 0.7, green: 0.45, blue: 1, alpha: 1), .white,
    ]
    private static let images: [UIImage] = {
        let shapes: [(CGSize, Bool)] = [(CGSize(width: 14, height: 8), false), (CGSize(width: 9, height: 9), true),
                                        (CGSize(width: 6, height: 16), false)]
        return shapes.map { size, round in
            UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor.white.setFill()
                let rect = CGRect(origin: .zero, size: size)
                if round { ctx.cgContext.fillEllipse(in: rect) } else { ctx.cgContext.fill(rect) }
            }
        }
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func cells(speed: CGFloat, birth: Float) -> [CAEmitterCell] {
        var out: [CAEmitterCell] = []
        for color in Self.colors {
            for img in Self.images {
                let c = CAEmitterCell()
                c.contents = img.cgImage
                c.color = color.cgColor
                c.birthRate = birth
                c.lifetime = 7
                c.velocity = speed
                c.velocityRange = speed * 0.45
                c.emissionRange = .pi / 7
                c.yAcceleration = 260
                c.spin = 4
                c.spinRange = 8
                c.scale = 1
                c.scaleRange = 0.5
                c.alphaSpeed = -0.12
                out.append(c)
            }
        }
        return out
    }

    func fire(big: Bool) {
        layoutIfNeeded()
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fire(big: big) }
            return
        }
        // two cannons from the bottom corners
        for (x, angle) in [(CGFloat(0), -CGFloat.pi / 3), (w, -2 * CGFloat.pi / 3)] {
            let e = CAEmitterLayer()
            e.emitterPosition = CGPoint(x: x, y: h + 10)
            e.emitterShape = .point
            e.emitterCells = cells(speed: big ? 1100 : 850, birth: big ? 22 : 12)
            e.emitterCells?.forEach { $0.emissionLongitude = angle }
            e.beginTime = CACurrentMediaTime()
            layer.addSublayer(e)
            stop(e, after: big ? 0.55 : 0.35)
        }
        // rain from the top
        let rain = CAEmitterLayer()
        rain.emitterPosition = CGPoint(x: w / 2, y: -20)
        rain.emitterShape = .line
        rain.emitterSize = CGSize(width: w, height: 1)
        rain.emitterCells = cells(speed: 120, birth: big ? 5 : 2)
        rain.emitterCells?.forEach { $0.emissionLongitude = .pi / 2; $0.yAcceleration = 120; $0.emissionRange = .pi / 4 }
        rain.beginTime = CACurrentMediaTime()
        layer.addSublayer(rain)
        stop(rain, after: big ? 2.6 : 1.4)
    }

    private func stop(_ e: CAEmitterLayer, after: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + after + 8) { e.removeFromSuperlayer() }
    }
}

// MARK: - Synthesized fanfare (no audio files needed)

final class Fanfare {
    static let shared = Fanfare()
    private var player: AVAudioPlayer?
    private lazy var full: Data = Self.make(notes: [(523.25, 0.0), (659.25, 0.11), (783.99, 0.22), (1046.5, 0.33),
                                                    (783.99, 0.55), (1046.5, 0.66)], tail: 1.3)
    private lazy var short: Data = Self.make(notes: [(783.99, 0.0), (1046.5, 0.12)], tail: 0.9)

    func play(short isShort: Bool) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: isShort ? short : full)
        player?.volume = 1
        player?.play()
    }

    /// Bell-like tones (fundamental + harmonics, exponential decay) mixed into a 16-bit WAV.
    private static func make(notes: [(Double, Double)], tail: Double) -> Data {
        let rate = 44100.0
        let total = (notes.map { $0.1 }.max() ?? 0) + tail
        let n = Int(total * rate)
        var buf = [Double](repeating: 0, count: n)
        for (freq, startT) in notes {
            let s0 = Int(startT * rate)
            for i in s0..<n {
                let t = Double(i - s0) / rate
                let env = min(1, t / 0.006) * exp(-t * 3.2)
                let v = sin(2 * .pi * freq * t) + 0.35 * sin(4 * .pi * freq * t) * exp(-t * 6) + 0.15 * sin(6 * .pi * freq * t) * exp(-t * 9)
                buf[i] += v * env * 0.28
            }
        }
        var pcm = Data(capacity: n * 2)
        for v in buf {
            var s = Int16(max(-1, min(1, v)) * 32000).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

/// Small "rendering…" indicator for the sidebar.
struct RenderingBadge: View {
    let names: [String]
    @State private var blink = false

    init(names: [String]) {
        self.names = names
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.bad)
                .frame(width: 9, height: 9)
                .opacity(blink ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(), value: blink)
            VStack(alignment: .leading, spacing: 1) {
                Text("Duke renderuar…")
                    .font(.system(size: 12, weight: .bold))
                Text(names.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bad.opacity(0.14)))
        .onAppear { blink = true }
    }
}

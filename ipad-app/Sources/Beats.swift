import SwiftUI

/// "Ritmi": beat markers for Premiere / Resolve / After Effects.
struct BeatsView: View {
    @EnvironmentObject var conn: Connection
    @AppStorage("usbdeck.beatsMode") private var mode = "all"
    @AppStorage("usbdeck.beatsFps") private var fps = 25
    @State private var offsetMs: Double = 0

    private let modes: [(String, String)] = [("all", "Çdo beat"), ("half", "Çdo i 2-ti"),
                                             ("bar", "Çdo takt (1/4)"), ("strong", "Vetëm të fortët")]

    private func selected(_ r: BeatsResult) -> [BeatPoint] {
        switch mode {
        case "half": return r.beats.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        case "bar": return r.beats.filter { $0.bar }
        case "strong": return r.beats.filter { $0.s >= 0.6 }
        default: return r.beats
        }
    }

    private var busy: Bool {
        guard let st = conn.beatsStatus else { return false }
        return st.state != "idle"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Ritmi").font(.system(size: 22, weight: .bold))
                    Text("markera në çdo beat").font(.system(size: 13)).foregroundColor(Theme.textDim)
                    Spacer()
                    Button { conn.beatsPick() } label: {
                        Label(conn.beats == nil ? "Zgjidh këngën në PC" : "Këngë tjetër", systemImage: "music.note.list")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .disabled(!conn.connected || busy)
                }

                if let st = conn.beatsStatus, !st.text.isEmpty {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(.white) }
                        Text(st.text).font(.system(size: 13)).foregroundColor(Theme.textDim)
                    }
                }

                if let r = conn.beats {
                    let sel = selected(r)
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f", r.bpm))
                                .font(.system(size: 54, weight: .heavy, design: .rounded))
                            Text("BPM").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.textDim)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            Text("\(formatTime(r.duration)) · \(r.beats.count) beat · \(sel.count) markera të zgjedhur")
                                .font(.system(size: 13)).foregroundColor(Theme.textDim)
                        }
                    }

                    WaveformView(wave: r.wave, duration: r.duration, beats: r.beats,
                                 selected: Set(sel.map { $0.t }), offset: offsetMs / 1000)
                        .frame(height: 120)

                    Picker("", selection: $mode) {
                        ForEach(modes, id: \.0) { m in Text(m.1).tag(m.0) }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 12) {
                        Text("Zhvendosja").font(.system(size: 13, weight: .semibold))
                        Slider(value: $offsetMs, in: -200...200, step: 10).tint(Theme.accent)
                        Text("\(Int(offsetMs)) ms").font(.system(size: 13, design: .monospaced)).frame(width: 64)
                        Picker("", selection: $fps) {
                            Text("24 fps").tag(24)
                            Text("25 fps").tag(25)
                            Text("30 fps").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                    }

                    HStack(spacing: 10) {
                        exportButton("Premiere", "film", Color(red: 0.36, green: 0.36, blue: 0.84), target: "premiere")
                        exportButton("Resolve", "paintpalette.fill", Color(red: 0.82, green: 0.26, blue: 0.23), target: "resolve")
                        exportButton("After Effects", "sparkles", Color(red: 0.48, green: 0.31, blue: 0.84), target: "ae")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("• Premiere: krijohet një XML pranë këngës → File › Import → sekuencë e re me këngën dhe markerat.")
                        Text("• Resolve: krijohet një EDL → në timeline: Timeline › Import › Timeline Markers from EDL.")
                        Text("• After Effects: zgjidh layer-in e muzikës në timeline, pastaj prek butonin.")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textDim)
                } else if !busy {
                    VStack(spacing: 10) {
                        Image(systemName: "metronome")
                            .font(.system(size: 46))
                            .foregroundColor(Theme.textDim)
                        Text("Zgjidh një këngë (MP3, WAV, M4A…) dhe vendosen markera në ritëm – për prerje në beat.")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(16)
        }
        .foregroundColor(.white)
    }

    private func exportButton(_ title: String, _ symbol: String, _ color: Color, target: String) -> some View {
        Button {
            conn.beatsExport(target: target, mode: mode, offset: offsetMs / 1000, fps: fps)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(color))
                .foregroundColor(.white)
        }
        .disabled(!conn.connected)
    }
}

private struct WaveformView: View {
    let wave: [Double]
    let duration: Double
    let beats: [BeatPoint]
    let selected: Set<Double>
    let offset: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
                Path { p in
                    let n = max(wave.count, 1)
                    let step = w / CGFloat(n)
                    for (i, v) in wave.enumerated() {
                        let x = CGFloat(i) * step + step / 2
                        let bh = max(2, CGFloat(v) * (h - 20))
                        p.move(to: CGPoint(x: x, y: h / 2 - bh / 2))
                        p.addLine(to: CGPoint(x: x, y: h / 2 + bh / 2))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: max(1, w / CGFloat(max(wave.count, 1)) * 0.6))
                Path { p in
                    guard duration > 0 else { return }
                    for b in beats where selected.contains(b.t) {
                        let x = CGFloat((b.t + offset) / duration) * w
                        let top: CGFloat = b.bar ? 4 : 18
                        p.move(to: CGPoint(x: x, y: top))
                        p.addLine(to: CGPoint(x: x, y: h - top))
                    }
                }
                .stroke(Theme.accent, lineWidth: 1.5)
            }
        }
    }
}

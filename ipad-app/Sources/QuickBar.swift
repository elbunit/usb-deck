import SwiftUI

/// Always-visible bottom bar: PC volume, mute, microphone and a full-screen screenshot.
/// Shown on every profile and every tool.
struct QuickBar: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var np: NowPlaying
    let openMusic: () -> Void
    @State private var flash = false

    init(openMusic: @escaping () -> Void = {}) {
        self.openMusic = openMusic
    }

    private var master: AudioLevel? {
        guard let m = conn.mixer, m.available else { return nil }
        return m.master
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mute
            Button {
                conn.toggleMute(target: "master", key: "")
            } label: {
                Image(systemName: speakerSymbol)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 46, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(master?.muted == true ? Theme.bad : Theme.raised))
            }
            .disabled(master == nil)

            // Volume
            if let m = master {
                HorizontalFader(value: m.volume, muted: m.muted) { v in
                    conn.setVolume(target: "master", key: "", value: v)
                }
                .frame(height: 40)
            } else {
                Text(conn.connected ? "Zëri i PC-së s'është gati" : "Pa lidhje me PC-në")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Microphone
            if let mic = conn.mixer?.mic {
                Button {
                    conn.toggleMute(target: "mic", key: "")
                } label: {
                    Image(systemName: mic.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(mic.muted ? Theme.bad : Theme.raised))
                }
            }

            // Now playing
            MiniPlayer(onOpen: openMusic)

            // Screenshot
            Button {
                conn.screenshot()
                flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.easeOut(duration: 0.45)) { flash = false }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "camera.fill")
                    if !(np.available && np.active) {
                        Text("Screenshot")
                    }
                }
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.48, green: 0.31, blue: 0.84)))
            }
            .disabled(!conn.connected)
            .opacity(conn.connected ? 1 : 0.5)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .top)
        .overlay(Color.white.opacity(flash ? 0.5 : 0).allowsHitTesting(false))
    }

    private var speakerSymbol: String {
        guard let m = master else { return "speaker.fill" }
        if m.muted || m.volume < 0.01 { return "speaker.slash.fill" }
        if m.volume < 0.34 { return "speaker.wave.1.fill" }
        if m.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Horizontal volume fader with relative drag (a tap never jumps the volume).
private struct HorizontalFader: View {
    let value: Double
    let muted: Bool
    let onChange: (Double) -> Void

    @State private var dragValue: Double?
    @State private var dragStart: Double?
    @State private var lastSent = Date.distantPast
    @State private var releaseWork: DispatchWorkItem?

    init(value: Double, muted: Bool, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.muted = muted
        self.onChange = onChange
    }

    private var shown: Double { min(max(dragValue ?? value, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.7), Theme.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, w * CGFloat(shown)))
                    .opacity(muted ? 0.3 : 1)
                Text("Volumi i PC-së  \(Int((shown * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.leading, 12)
                    .foregroundColor(.white)
                Capsule()
                    .fill(Color.white)
                    .frame(width: 5, height: geo.size.height * 0.62)
                    .offset(x: max(0, min(w * CGFloat(shown) - 5, w - 5)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        releaseWork?.cancel()
                        if dragStart == nil { dragStart = shown }
                        let v = min(max((dragStart ?? 0) + Double(g.translation.width / max(w, 1)), 0), 1)
                        dragValue = v
                        if Date().timeIntervalSince(lastSent) > 0.04 {
                            lastSent = Date()
                            onChange(v)
                        }
                    }
                    .onEnded { _ in
                        if let v = dragValue { onChange(v) }
                        dragStart = nil
                        let work = DispatchWorkItem { dragValue = nil }
                        releaseWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
                    }
            )
        }
    }
}

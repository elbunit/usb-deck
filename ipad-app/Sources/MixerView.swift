import SwiftUI

/// Windows volume mixer: master, per-app channels, microphone and output device.
struct MixerView: View {
    @EnvironmentObject var conn: Connection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Mikseri")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                if let mic = conn.mixer?.mic {
                    MicButton(muted: mic.muted) { conn.toggleMute(target: "mic", key: "") }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if let mixer = conn.mixer, mixer.available {
                if let outputs = mixer.outputs, outputs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Image(systemName: "hifispeaker.2.fill")
                                .foregroundColor(Theme.textDim)
                            ForEach(outputs) { o in
                                Button { conn.setOutput(o.id) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: outputSymbol(o.name))
                                        Text(o.name).lineLimit(1)
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(o.isDefault ? Theme.accent : Theme.raised))
                                    .foregroundColor(.white)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        if let master = mixer.master {
                            ChannelStrip(name: "Kompjuteri", symbol: "desktopcomputer", volume: master.volume,
                                         muted: master.muted, active: true, tint: Theme.accent, width: 118,
                                         onVolume: { conn.setVolume(target: "master", key: "", value: $0) },
                                         onMute: { conn.toggleMute(target: "master", key: "") })
                            Rectangle().fill(Theme.stroke).frame(width: 1)
                        }
                        ForEach(mixer.apps ?? []) { app in
                            ChannelStrip(name: app.name, symbol: app.symbol ?? "speaker.wave.2.fill", volume: app.volume,
                                         muted: app.muted, active: app.active,
                                         tint: Color(red: 0.2, green: 0.75, blue: 0.55), width: 92,
                                         onVolume: { conn.setVolume(target: "app", key: app.key, value: $0) },
                                         onMute: { conn.toggleMute(target: "app", key: app.key) })
                        }
                        if (mixer.apps ?? []).isEmpty {
                            Text("Asnjë aplikacion nuk po luan zë tani.")
                                .foregroundColor(Theme.textDim)
                                .padding()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "speaker.badge.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundColor(Theme.textDim)
                    Text(conn.connected ? "Mikseri nuk është gati në PC." : "Lidh iPad-in me PC-në.")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Agjenti duhet të ketë librarinë pycaw (instalohet vetë nga “Start USB Deck”).")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textDim)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .foregroundColor(.white)
    }

    private func outputSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("head") || n.contains("kufj") || n.contains("airpods") || n.contains("buds") { return "headphones" }
        if n.contains("hdmi") || n.contains("display") || n.contains("monitor") || n.contains("tv") { return "tv" }
        return "hifispeaker.fill"
    }
}

private struct MicButton: View {
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                Text(muted ? "Mikrofoni FIKUR" : "Mikrofoni NDEZUR")
            }
            .font(.system(size: 14, weight: .bold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(muted ? Theme.bad : Theme.ok.opacity(0.25)))
            .overlay(Capsule().strokeBorder(muted ? Color.white.opacity(0.5) : Theme.ok, lineWidth: 1))
            .foregroundColor(.white)
        }
    }
}

private struct ChannelStrip: View {
    let name: String
    let symbol: String
    let volume: Double
    let muted: Bool
    let active: Bool
    let tint: Color
    let width: CGFloat
    let onVolume: (Double) -> Void
    let onMute: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.raised)
                Image(systemName: Symbols.valid(symbol) ?? "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 42, height: 42)
            .overlay(Circle().fill(active ? Theme.ok : Color.clear).frame(width: 9, height: 9), alignment: .topTrailing)

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
                .frame(height: 30)

            VolumeSlider(value: volume, muted: muted, tint: tint, onChange: onVolume)

            Button(action: onMute) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(muted ? Theme.bad : Theme.raised))
                    .foregroundColor(.white)
            }
        }
        .padding(8)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .opacity(active || muted ? 1 : 0.8)
    }
}

/// Tall vertical fader. Relative drag (no jump on tap), throttled sends.
private struct VolumeSlider: View {
    let value: Double
    let muted: Bool
    let tint: Color
    let onChange: (Double) -> Void

    @State private var dragValue: Double?
    @State private var dragStart: Double?
    @State private var lastSent = Date.distantPast
    @State private var releaseWork: DispatchWorkItem?

    init(value: Double, muted: Bool, tint: Color, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.muted = muted
        self.tint = tint
        self.onChange = onChange
    }

    private var shown: Double { min(max(dragValue ?? value, 0), 1) }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int((shown * 100).rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(muted ? Theme.bad : .white)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised)
                    VStack(spacing: 0) {
                        ForEach(0..<10, id: \.self) { _ in
                            Spacer(minLength: 0)
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                        }
                        Spacer(minLength: 0)
                    }
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(height: max(0, h * CGFloat(shown)))
                        .opacity(muted ? 0.3 : 1)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * 0.62, height: 5)
                        .offset(y: -max(0, h * CGFloat(shown) - 5))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            releaseWork?.cancel()
                            if dragStart == nil { dragStart = shown }
                            let v = min(max((dragStart ?? 0) - Double(g.translation.height / max(h, 1)), 0), 1)
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
            .frame(minHeight: 160)
        }
    }
}

import Combine
import SwiftUI
import UIKit

/// Now-playing state (Spotify, YouTube in the browser, VLC...) read from Windows.
final class NowPlaying: ObservableObject {
    @Published var available = false
    @Published var active = false
    @Published var app = ""
    @Published var exe = ""
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var canSeek = false
    @Published var cover: UIImage?
    @Published var source: String?
    @Published var sources: [MediaSourceItem] = []

    private var coverID = -1
    private var positionStamp = Date()

    func apply(_ m: MediaMessage) {
        available = m.available ?? false
        active = m.active ?? false
        app = m.app ?? ""
        exe = m.exe ?? ""
        title = m.title ?? ""
        artist = m.artist ?? ""
        album = m.album ?? ""
        playing = m.playing ?? false
        duration = m.duration ?? 0
        canSeek = m.can_seek ?? false
        source = m.source
        sources = m.sources ?? []
        if let p = m.position { setPosition(p) }
        if let id = m.cover_id, id != coverID {
            coverID = id
            if let b64 = m.cover, let data = Data(base64Encoded: b64) {
                cover = UIImage(data: data)
            } else {
                cover = nil
            }
        }
    }

    func applyPosition(_ m: MediaPosMessage) {
        playing = m.playing
        duration = m.duration
        setPosition(m.position)
    }

    private func setPosition(_ p: Double) {
        position = p
        positionStamp = Date()
    }

    /// Position extrapolated between the 1-second updates (smooth progress bar).
    func livePosition(at date: Date) -> Double {
        guard playing else { return position }
        let p = position + date.timeIntervalSince(positionStamp)
        return duration > 0 ? min(p, duration) : p
    }
}

func formatTime(_ s: Double) -> String {
    let t = max(0, Int(s.rounded(.down)))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Full screen "Muzika"

struct MusicView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var np: NowPlaying
    @State private var scrub: Double?

    private var appVolume: AppAudio? {
        guard !np.exe.isEmpty else { return nil }
        return conn.mixer?.apps?.first { $0.key == np.exe }
    }

    var body: some View {
        ZStack {
            // Blurred cover as background
            if let img = np.cover {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .opacity(0.45)
                    .clipped()
                    .ignoresSafeArea()
            }
            LinearGradient(colors: [Color.black.opacity(0.2), Color.black.opacity(0.75)], startPoint: .top, endPoint: .bottom)

            if !np.available {
                message("Muzika s'është gati në PC", "Hap prapë “Start USB Deck” – instalon vetë paketat që duhen.")
            } else if !np.active {
                message("Asgjë nuk po luan", "Hap Spotify, YouTube ose një video – shfaqet këtu automatikisht.")
            } else {
                HStack(spacing: 32) {
                    coverView
                        .frame(width: 300, height: 300)
                    controls
                        .frame(maxWidth: .infinity)
                }
                .padding(32)
            }
        }
        .foregroundColor(.white)
    }

    private var coverView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.raised)
            if let img = np.cover {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 90, weight: .light))
                    .foregroundColor(Theme.textDim)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if np.sources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(np.sources) { s in
                            Button { conn.mediaCommand("select", value: s.id) } label: {
                                Text(s.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(s.id == np.source ? Color.white.opacity(0.3) : Color.white.opacity(0.1)))
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // Only the source is shown (YouTube, Spotify…), never the song title.
                Text(np.app.isEmpty ? "Media" : np.app)
                    .font(.system(size: 34, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Circle().fill(np.playing ? Theme.ok : Color.white.opacity(0.4)).frame(width: 8, height: 8)
                    Text(np.playing ? "Po luan" : "Në pauzë")
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color.white.opacity(0.75))
            }

            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let live = scrub ?? np.livePosition(at: ctx.date)
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let frac = np.duration > 0 ? min(max(live / np.duration, 0), 1) : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2)).frame(height: 6)
                            Capsule().fill(Color.white).frame(width: geo.size.width * CGFloat(frac), height: 6)
                            Circle().fill(Color.white).frame(width: 16, height: 16)
                                .offset(x: geo.size.width * CGFloat(frac) - 8)
                                .opacity(np.canSeek ? 1 : 0)
                        }
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    guard np.canSeek, np.duration > 0 else { return }
                                    scrub = min(max(Double(v.location.x / geo.size.width), 0), 1) * np.duration
                                }
                                .onEnded { _ in
                                    if let s = scrub { conn.mediaCommand("seek", value: s) }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { scrub = nil }
                                }
                        )
                    }
                    .frame(height: 24)
                    HStack {
                        Text(formatTime(live))
                        Spacer()
                        Text(np.duration > 0 ? "-" + formatTime(np.duration - live) : "")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.7))
                }
            }

            HStack(spacing: 34) {
                Spacer()
                bigButton("backward.fill", size: 30) { conn.mediaCommand("prev") }
                Button { conn.mediaCommand("toggle") } label: {
                    Image(systemName: np.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .bold))
                        .frame(width: 86, height: 86)
                        .background(Circle().fill(Color.white))
                        .foregroundColor(.black)
                }
                bigButton("forward.fill", size: 30) { conn.mediaCommand("next") }
                Spacer()
            }

            if let av = appVolume {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundColor(Color.white.opacity(0.7))
                    Slider(value: Binding(get: { av.volume },
                                          set: { conn.setVolume(target: "app", key: av.key, value: $0) }),
                           in: 0...1)
                        .tint(.white)
                    Image(systemName: "speaker.wave.3.fill").foregroundColor(Color.white.opacity(0.7))
                }
                Text("Volumi i \(np.app)")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))
            }
        }
    }

    private func bigButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: 64, height: 64)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(Theme.textDim)
            Text(title).font(.system(size: 22, weight: .bold))
            Text(detail).font(.system(size: 14)).foregroundColor(Theme.textDim).multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

// MARK: - Mini player for the bottom bar

struct MiniPlayer: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var np: NowPlaying
    let onOpen: () -> Void

    var body: some View {
        if np.available && np.active {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 8) {
                        Group {
                            if let img = np.cover {
                                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "music.note").font(.system(size: 14))
                            }
                        }
                        .frame(width: 32, height: 32)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(np.app.isEmpty ? "Media" : np.app)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 84, alignment: .leading)
                    }
                }
                Button { conn.mediaCommand("toggle") } label: {
                    Image(systemName: np.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                }
            }
            .foregroundColor(.white)
        }
    }
}

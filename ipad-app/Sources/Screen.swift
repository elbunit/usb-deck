import SwiftUI
import UIKit

/// Live picture of a PC monitor / window, streamed over USB.
final class ScreenModel: ObservableObject {
    @Published var image: UIImage?
    @Published var cursor: CGPoint?          // normalised 0..1
    @Published var sources: [ScreenSource] = []
    @Published var current = "m1"
    @Published var fps = 0

    private var frames = 0
    private var windowStart = Date()

    func show(_ img: UIImage) {
        image = img
        frames += 1
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1 {
            fps = frames
            frames = 0
            windowStart = now
        }
    }

    func setCursor(_ x: Double?, _ y: Double?) {
        if let x = x, let y = y, x >= 0, x <= 1, y >= 0, y <= 1 {
            cursor = CGPoint(x: x, y: y)
        } else {
            cursor = nil
        }
    }

    func reset() {
        image = nil
        fps = 0
        frames = 0
    }
}

struct ScreenView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var model: ScreenModel
    @Binding var fullscreen: Bool
    @AppStorage("usbdeck.screenSource") private var savedSource = "m1"
    @AppStorage("usbdeck.screenTouch") private var touchEnabled = false
    @State private var touching = false
    @State private var lastMove = Date.distantPast
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                if let img = model.image {
                    let rect = fitRect(image: img.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        if let c = model.cursor {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                                .position(x: rect.minX + c.x * rect.width, y: rect.minY + c.y * rect.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(touchGesture(rect: rect))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if !touchEnabled { withAnimation { showControls.toggle() } }
                    })
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(conn.connected ? "Duke marrë pamjen e ekranit…" : "Lidh iPad-in me PC-në")
                            .foregroundColor(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if showControls || !fullscreen {
                controls
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            model.reset()
            conn.screenStart(savedSource)
        }
        .onDisappear { conn.screenStop() }
        .onChange(of: conn.connected) { ok in if ok { conn.screenStart(savedSource) } }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.sources) { s in
                    Button {
                        savedSource = s.id
                        model.current = s.id
                        model.reset()
                        conn.screenStart(s.id)
                    } label: {
                        Label("\(s.name)  \(s.detail ?? "")", systemImage: s.id == "window" ? "macwindow" : "display")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.current == "window" ? "macwindow" : "display")
                    Text(model.sources.first { $0.id == model.current }?.name ?? "Monitori")
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.65)))
            }

            Button {
                touchEnabled.toggle()
            } label: {
                Label(touchEnabled ? "Prekja: ON" : "Prekja: OFF", systemImage: touchEnabled ? "hand.point.up.left.fill" : "hand.raised.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(touchEnabled ? Theme.accent : Color.black.opacity(0.65)))
            }

            Spacer()

            Text("\(model.fps) fps")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.65)))

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { fullscreen.toggle() }
                showControls = true
            } label: {
                Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 34)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
            }
        }
        .foregroundColor(.white)
        .padding(10)
    }

    // MARK: Touch -> mouse

    private func touchGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard touchEnabled else { return }
                let p = normalise(v.location, rect)
                if !touching {
                    touching = true
                    conn.screenTouch(x: p.x, y: p.y, action: "down")
                } else if Date().timeIntervalSince(lastMove) > 0.03 {
                    lastMove = Date()
                    conn.screenTouch(x: p.x, y: p.y, action: "move")
                }
            }
            .onEnded { v in
                guard touchEnabled else { return }
                let p = normalise(v.location, rect)
                conn.screenTouch(x: p.x, y: p.y, action: "up")
                touching = false
            }
    }

    private func normalise(_ pt: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: min(max((pt.x - rect.minX) / max(rect.width, 1), 0), 1),
                y: min(max((pt.y - rect.minY) / max(rect.height, 1), 0), 1))
    }

    private func fitRect(image: CGSize, in box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: box) }
        let scale = min(box.width / image.width, box.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}

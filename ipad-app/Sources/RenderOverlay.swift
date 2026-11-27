import AudioToolbox
import SwiftUI
import UIKit

/// Full-screen, impossible-to-miss "render finished" screen.
struct RenderDoneOverlay: View {
    let event: RenderEvent
    let onReveal: () -> Void
    let onClose: () -> Void

    @State private var appeared = false
    @State private var pulse = false
    @State private var flash = true
    @State private var previousBrightness: CGFloat = 0.8

    init(event: RenderEvent, onReveal: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.event = event
        self.onReveal = onReveal
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.55, blue: 0.32), Color(red: 0.02, green: 0.25, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            // Expanding rings
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                    .frame(width: 220, height: 220)
                    .scaleEffect(pulse ? 3.2 : 0.8)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: pulse)
            }

            // Attention flash at the start
            Color.white
                .opacity(flash ? 0.35 : 0)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25).repeatCount(5, autoreverses: true), value: flash)

            VStack(spacing: 22) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 130, weight: .bold))
                    .foregroundColor(.white)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .shadow(color: .black.opacity(0.3), radius: 20)

                Text("RENDER-I PËRFUNDOI")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)

                Text(event.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                HStack(spacing: 14) {
                    if let size = event.size { infoChip("internaldrive.fill", size) }
                    if let duration = event.duration { infoChip("timer", duration) }
                    if let finished = event.finished { infoChip("clock.fill", finished) }
                }

                HStack(spacing: 14) {
                    if !event.path.isEmpty {
                        Button(action: onReveal) {
                            Label("Hap dosjen në PC", systemImage: "folder.fill")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                                .background(Capsule().fill(Color.white.opacity(0.18)))
                                .foregroundColor(.white)
                        }
                    }
                    Button(action: onClose) {
                        Text("OK")
                            .font(.system(size: 18, weight: .heavy))
                            .padding(.horizontal, 44)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Color.white))
                            .foregroundColor(Color(red: 0.03, green: 0.35, blue: 0.2))
                    }
                }
                .padding(.top, 10)
            }
            .opacity(appeared ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .onAppear {
            previousBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { appeared = true }
            pulse = true
            flash = false
            AudioServicesPlaySystemSound(1005)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { AudioServicesPlaySystemSound(1005) }
        }
        .onDisappear {
            UIScreen.main.brightness = previousBrightness
        }
    }

    private func infoChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Symbols.valid(symbol) ?? "circle.fill")
            Text(text)
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .foregroundColor(.white)
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

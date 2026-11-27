import SwiftUI

/// One pad on the grid. Sends "down" on touch and "up" on release so the
/// PC agent can do tap, hold (key held down) and auto-repeat.
struct DeckButtonView: View {
    let button: DeckButton?
    let fallbackColor: Color
    let onDown: () -> Void
    let onUp: () -> Void

    @State private var pressed = false

    init(button: DeckButton?, fallbackColor: Color, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.button = button
        self.fallbackColor = fallbackColor
        self.onDown = onDown
        self.onUp = onUp
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            if let button = button {
                let base = Color(hex: button.color, fallback: fallbackColor)
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                        .fill(LinearGradient(colors: [base.opacity(pressed ? 1.0 : 0.92),
                                                      base.opacity(pressed ? 0.85 : 0.62)],
                                             startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                        .strokeBorder(Color.white.opacity(pressed ? 0.55 : 0.10), lineWidth: pressed ? 2 : 1)

                    VStack(spacing: side * 0.06) {
                        if let symbol = Symbols.valid(button.symbol) {
                            Image(systemName: symbol)
                                .font(.system(size: side * 0.28, weight: .semibold))
                                .frame(height: side * 0.34)
                        }
                        Text(button.label)
                            .font(.system(size: max(11, side * (Symbols.valid(button.symbol) == nil ? 0.17 : 0.125)),
                                          weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundColor(.white)
                    .padding(side * 0.08)

                    if let badge = badgeSymbol(button.mode) {
                        Image(systemName: badge)
                            .font(.system(size: max(9, side * 0.1), weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(side * 0.08)
                    }
                }
                .scaleEffect(pressed ? 0.94 : 1.0)
                .shadow(color: base.opacity(pressed ? 0.6 : 0.0), radius: pressed ? 12 : 0)
                .animation(.easeOut(duration: 0.08), value: pressed)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !pressed {
                                pressed = true
                                onDown()
                            }
                        }
                        .onEnded { _ in
                            if pressed {
                                pressed = false
                                onUp()
                            }
                        }
                )
                .onDisappear {
                    if pressed {
                        pressed = false
                        onUp()
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }

    private func badgeSymbol(_ mode: String?) -> String? {
        switch mode {
        case "hold": return Symbols.valid("hand.point.down.fill") ?? Symbols.valid("hand.tap.fill")
        case "repeat": return Symbols.valid("repeat")
        default: return nil
        }
    }
}

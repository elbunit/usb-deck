import SwiftUI
import UIKit

/// A panel hidden off one edge of the screen. Only a small handle stays visible;
/// drag the handle (or tap it) to slide the panel in, drag back / tap outside to hide it.
struct EdgeDrawer<Handle: View, Content: View>: View {
    enum Side { case leading, trailing, top }

    let side: Side
    let size: CGFloat
    @Binding var open: Bool
    let handle: (Bool) -> Handle
    let content: () -> Content
    @State private var drag: CGFloat = 0

    init(side: Side, size: CGFloat, open: Binding<Bool>,
         @ViewBuilder handle: @escaping (Bool) -> Handle,
         @ViewBuilder content: @escaping () -> Content) {
        self.side = side
        self.size = size
        self._open = open
        self.handle = handle
        self.content = content
    }

    private var alignment: Alignment {
        switch side {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        }
    }

    /// Offset that hides the panel (handle stays on screen).
    private var closedOffset: CGFloat {
        switch side {
        case .leading, .top: return -size
        case .trailing: return size
        }
    }

    private var current: CGFloat {
        let base = open ? 0 : closedOffset
        let lo = min(0, closedOffset), hi = max(0, closedOffset)
        return min(hi, max(lo, base + drag))
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if open {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { open = false }
                    .transition(.opacity)
            }
            stack
                .offset(x: side == .top ? 0 : current, y: side == .top ? current : 0)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { v in drag = side == .top ? v.translation.height : v.translation.width }
                        .onEnded { v in
                            let predicted = side == .top ? v.predictedEndTranslation.height : v.predictedEndTranslation.width
                            let dir: CGFloat = closedOffset > 0 ? 1 : -1      // direction that hides the panel
                            drag = 0
                            if open { open = !(predicted * dir > size * 0.35) } else { open = predicted * dir < -size * 0.2 }
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86), value: open)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: drag)
    }

    @ViewBuilder private var stack: some View {
        switch side {
        case .trailing:
            HStack(spacing: 0) {
                handleButton
                panel.frame(width: size).frame(maxHeight: .infinity)
            }
        case .leading:
            HStack(spacing: 0) {
                panel.frame(width: size).frame(maxHeight: .infinity)
                handleButton
            }
        case .top:
            VStack(spacing: 0) {
                panel.frame(height: size).frame(maxWidth: .infinity)
                handleButton
            }
        }
    }

    private var handleButton: some View {
        Button { open.toggle() } label: { handle(open) }
            .buttonStyle(.plain)
    }

    private var panel: some View {
        content()
            .background(
                Theme.panel
                    .overlay(edgeLine, alignment: innerEdge)
                    .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 24)
                    .ignoresSafeArea()
            )
    }

    private var innerEdge: Alignment {
        switch side {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        }
    }

    @ViewBuilder private var edgeLine: some View {
        if side == .top {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        } else {
            Rectangle().fill(Theme.stroke).frame(width: 1)
        }
    }
}

/// Tab shape for drawer handles: rounded only on the side facing the screen.
struct DrawerTabShape: Shape {
    let corners: UIRectCorner
    var radius: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

/// Vertical tab used on the left/right edges.
struct SideHandle: View {
    let symbol: String
    let open: Bool
    let tint: Color
    let corners: UIRectCorner
    let openSymbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: open ? openSymbol : symbol)
                .font(.system(size: 14, weight: .bold))
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 3, height: 22)
        }
        .foregroundColor(.white)
        .frame(width: 26, height: 96)
        .background(DrawerTabShape(corners: corners).fill(open ? Theme.panel : tint.opacity(0.85)))
        .shadow(color: .black.opacity(0.35), radius: 6)
        .opacity(open ? 1 : 0.8)
    }
}

import SwiftUI

/// Deck profiles (Premiere, After Effects, DaVinci...) in a drawer that slides down from the
/// TOP edge. The handle shows the active deck, so you always see which one is on.
struct ProfilesDrawer: View {
    @EnvironmentObject var conn: Connection
    let onSelect: (String) -> Void
    let activeHighlighted: Bool
    @State private var open = false

    init(activeHighlighted: Bool, onSelect: @escaping (String) -> Void) {
        self.activeHighlighted = activeHighlighted
        self.onSelect = onSelect
    }

    var body: some View {
        EdgeDrawer(side: .top, size: 150, open: $open) { isOpen in
            handle(isOpen)
        } content: {
            panel
        }
    }

    private func handle(_ isOpen: Bool) -> some View {
        let p = conn.activeProfile
        let tint = Color(hex: p?.color, fallback: Theme.accent)
        return HStack(spacing: 8) {
            Image(systemName: Symbols.valid(p?.symbol) ?? "square.grid.2x2")
                .font(.system(size: 13, weight: .bold))
            Text(p?.name ?? "Deck")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            if conn.autoFollow {
                Text("AUTO").font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
            }
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .heavy))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(DrawerTabShape(corners: [.bottomLeft, .bottomRight], radius: 12)
            .fill(isOpen ? Theme.panel : tint.opacity(0.9)))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private var panel: some View {
        HStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(conn.profiles) { p in
                        chip(p)
                    }
                }
                .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $conn.autoFollow) {
                    Text("Auto-profil").font(.system(size: 14, weight: .semibold))
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                Text("ndërrohet vetë sipas programit që ke përpara")
                    .font(.system(size: 10)).foregroundColor(Theme.textDim)
            }
            .frame(width: 190)
            .padding(.trailing, 18)
        }
        .padding(.top, 14)
        .foregroundColor(.white)
    }

    private func chip(_ p: Profile) -> some View {
        let active = p.id == conn.activeProfile?.id && activeHighlighted
        let tint = Color(hex: p.color, fallback: Theme.accent)
        return Button {
            onSelect(p.id)
            open = false
        } label: {
            VStack(spacing: 8) {
                Image(systemName: Symbols.valid(p.symbol) ?? "square.grid.2x2")
                    .font(.system(size: 26, weight: .semibold))
                Text(p.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 118, height: 96)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(active ? tint.opacity(0.95) : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(active ? Color.white.opacity(0.5) : tint.opacity(0.55), lineWidth: active ? 2 : 1))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

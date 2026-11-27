import SwiftUI
import UIKit

enum Tool: String, CaseIterable {
    case premiere, paths, scopes, mixer, music, screen, launcher, ai, beats, transfer, revisions, brands, projects, expressions, time, docs

    var title: String {
        switch self {
        case .premiere: return "Premiere"
        case .scopes: return "Scopes"
        case .mixer: return "Mikseri"
        case .music: return "Muzika"
        case .ai: return "Asistenti AI"
        case .beats: return "Ritmi"
        case .screen: return "Monitori"
        case .launcher: return "Programet"
        case .paths: return "Rrugët"
        case .transfer: return "Dërgo te PC"
        case .revisions: return "Korrigjime"
        case .brands: return "Brendet"
        case .projects: return "Projektet"
        case .expressions: return "Expressions"
        case .time: return "Koha"
        case .docs: return "Dokumente"
        }
    }

    var symbol: String {
        switch self {
        case .premiere: return "film.stack"
        case .scopes: return "waveform.path.ecg.rectangle"
        case .mixer: return "slider.vertical.3"
        case .music: return "music.note"
        case .ai: return "brain.head.profile"
        case .beats: return "metronome"
        case .screen: return "display"
        case .launcher: return "square.grid.2x2.fill"
        case .paths: return "text.insert"
        case .transfer: return "square.and.arrow.up.on.square"
        case .revisions: return "checklist"
        case .brands: return "paintpalette.fill"
        case .projects: return "folder.fill"
        case .expressions: return "curlybraces"
        case .time: return "timer"
        case .docs: return "doc.richtext"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var conn: Connection
    @State private var pageByProfile: [String: Int] = [:]
    @State private var showPanel = true
    @State private var panelTab = 0           // 0 = Jog, 1 = Ease
    @State private var jogModeByProfile: [String: String] = [:]
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = 0.8
    @State private var tool: Tool?
    @State private var screenFull = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            if conn.config == nil {
                WaitingView(connected: conn.connected)
            } else if let profile = conn.activeProfile {
                HStack(spacing: 0) {
                    if !screenFull {
                        Sidebar(profile: profile, showPanel: $showPanel, tool: $tool, dimmed: dimmed, toggleDim: toggleDim)
                            .frame(width: 190)
                            .background(Theme.panel)
                    }

                    VStack(spacing: 0) {
                    Group {
                        switch tool {
                        case .premiere: PremiereView()
                        case .scopes: ScopesView()
                        case .mixer: MixerView()
                        case .music: MusicView()
                        case .ai: AssistantView()
                        case .beats: BeatsView()
                        case .screen: ScreenView(fullscreen: $screenFull)
                        case .launcher: LauncherView()
                        case .paths: PathsView()
                        case .transfer: TransferView()
                        case .revisions: RevisionsView()
                        case .brands: BrandsView()
                        case .projects: ProjectsView()
                        case .expressions: ExpressionsView()
                        case .time: TimeView()
                        case .docs: DocsView()
                        case nil: mainArea(profile)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    if !screenFull {
                        QuickBar(openMusic: { tool = .music })
                    }
                    }

                    if showPanel && hasPanel(profile) && !screenFull {
                        sidePanel(profile)
                            .frame(width: 304)
                            .background(Theme.panel)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showPanel)
                .onChange(of: tool) { t in if t != .screen { screenFull = false } }
            }

            if let toast = conn.toast {
                Text(toast)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // banners on top of everything (except the full-screen render screens)
            VStack(spacing: 0) {
                RenderProgressStrip(jobs: Array(conn.renders.values))
                ExpiryBanner()
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)

            if let done = conn.renderDone, done.state == "failed" {
                RenderFailedOverlay(event: done,
                                    onReveal: {
                                        if !done.path.isEmpty { conn.reveal(done.path) }
                                        withAnimation { conn.renderDone = nil }
                                    },
                                    onClose: { withAnimation { conn.renderDone = nil } })
                    .transition(.opacity)
                    .zIndex(10)
            } else if let done = conn.renderDone {
                RenderDoneOverlay(event: done,
                                  onReveal: {
                                      conn.reveal(done.path)
                                      withAnimation { conn.renderDone = nil }
                                  },
                                  onClose: { withAnimation { conn.renderDone = nil } })
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
    }

    // MARK: Main grid

    private func mainArea(_ profile: Profile) -> some View {
        let pages = profile.pages
        let current = min(pageByProfile[profile.id] ?? 0, max(pages.count - 1, 0))
        let grid = profile.grid ?? conn.config?.grid ?? GridSize(rows: 4, cols: 5)

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if pages.count > 1 {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        Button {
                            pageByProfile[profile.id] = index
                        } label: {
                            Text(page.name)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(index == current ? Color(hex: profile.color, fallback: Theme.accent) : Theme.raised))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if pages.isEmpty {
                Spacer()
                Text("Ky profil nuk ka butona. Shtoji nga editori në PC.")
                    .foregroundColor(Theme.textDim)
                Spacer()
            } else {
                ButtonGrid(page: pages[current], grid: grid,
                           fallback: Color(hex: profile.color, fallback: Theme.defaultButton)) { button, down in
                    conn.buttonEvent(button, profile: profile, down: down)
                }
                .id("\(profile.id)-\(current)")
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .gesture(
                    DragGesture(minimumDistance: 60)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                            let next = value.translation.width < 0 ? current + 1 : current - 1
                            if next >= 0 && next < pages.count { pageByProfile[profile.id] = next }
                        }
                )
            }
        }
    }

    // MARK: Side panel (jog / ease)

    private func hasPanel(_ profile: Profile) -> Bool {
        profile.jog != nil || profile.ease == true
    }

    private func sidePanel(_ profile: Profile) -> some View {
        let showJog = profile.jog != nil
        let showEase = profile.ease == true
        let tab = (showJog && showEase) ? panelTab : (showJog ? 0 : 1)

        return VStack(spacing: 14) {
            if showJog && showEase {
                Picker("", selection: $panelTab) {
                    Text("Jog").tag(0)
                    Text("Easing").tag(1)
                }
                .pickerStyle(.segmented)
            }
            if tab == 0, let jog = profile.jog {
                jogPanel(profile, jog)
            } else {
                EaseEditorView(enabled: conn.connected) { curve in
                    conn.applyEase(curve)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func jogPanel(_ profile: Profile, _ jog: JogInfo) -> some View {
        let mode = jogModeByProfile[profile.id] ?? jog.modes.first?.id ?? "frame"
        return VStack(spacing: 14) {
            if jog.modes.count > 1 {
                Picker("", selection: Binding(get: { mode }, set: { jogModeByProfile[profile.id] = $0 })) {
                    ForEach(jog.modes) { m in Text(m.label).tag(m.id) }
                }
                .pickerStyle(.segmented)
            }
            JogWheelView { steps in
                conn.jog(profile: profile, mode: mode, steps: steps)
            }
            .aspectRatio(1, contentMode: .fit)

            if !jog.transport.isEmpty {
                HStack(spacing: 10) {
                    ForEach(jog.transport, id: \.self) { name in
                        Button {
                            conn.transport(profile: profile, name: name)
                        } label: {
                            Image(systemName: transportSymbol(name))
                                .font(.system(size: 22, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
        }
    }

    private func transportSymbol(_ name: String) -> String {
        switch name {
        case "reverse": return "backward.fill"
        case "stop": return "stop.fill"
        case "forward": return "forward.fill"
        case "play": return "playpause.fill"
        default: return "circle"
        }
    }

    private func toggleDim() {
        if dimmed {
            UIScreen.main.brightness = savedBrightness
        } else {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.12
        }
        dimmed.toggle()
    }
}

// MARK: - Grid

private struct ButtonGrid: View {
    let page: Page
    let grid: GridSize
    let fallback: Color
    let onEvent: (DeckButton, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let rows = max(grid.rows, 1)
            let cols = max(grid.cols, 1)
            let spacing: CGFloat = 10
            let cellW = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let fullH = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let cellH = min(fullH, cellW * 1.45)   // fill the height, but never absurdly tall
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(0..<cols, id: \.self) { c in
                            let index = r * cols + c
                            let button: DeckButton? = index < page.buttons.count ? page.buttons[index] : nil
                            DeckButtonView(button: button, fallbackColor: fallback,
                                           onDown: { if let b = button { onEvent(b, true) } },
                                           onUp: { if let b = button { onEvent(b, false) } })
                                .frame(width: max(cellW, 10), height: max(cellH, 10))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var transfers: TransferManager
    @EnvironmentObject var docs: DocStore
    let profile: Profile
    @Binding var showPanel: Bool
    @Binding var tool: Tool?
    let dimmed: Bool
    let toggleDim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundColor(Theme.accent)
                Text("USB Deck")
                    .font(.system(size: 18, weight: .heavy))
            }
            .padding(.top, 16)

            StatusPill(connected: conn.connected)

            if let app = conn.activeAppName, !app.isEmpty {
                Text(app)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)
            }

            if !conn.renders.isEmpty {
                RenderingBadge(jobs: conn.renders.values.sorted { $0.name < $1.name })
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5),
                                GridItem(.flexible(), spacing: 5)], spacing: 5) {
                ForEach(Tool.allCases, id: \.self) { t in
                    toolTile(t, badge: badge(for: t))
                }
            }

            Divider().background(Theme.stroke)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(conn.profiles) { p in
                        Button {
                            tool = nil
                            conn.selectProfileManually(p.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: Symbols.valid(p.symbol) ?? "square.grid.2x2")
                                    .frame(width: 22)
                                Text(p.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(p.id == profile.id && tool == nil ? Color(hex: p.color, fallback: Theme.accent).opacity(0.9) : Color.clear)
                            )
                            .foregroundColor(.white)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Toggle(isOn: $conn.autoFollow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-profil").font(.system(size: 13, weight: .semibold))
                    Text("ndjek app-in aktiv").font(.system(size: 10)).foregroundColor(Theme.textDim)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

            HStack(spacing: 8) {
                SidebarIconButton(symbol: showPanel ? "sidebar.right" : "sidebar.squares.right", active: showPanel) {
                    showPanel.toggle()
                }
                SidebarIconButton(symbol: dimmed ? "sun.max.fill" : "moon.fill", active: dimmed, action: toggleDim)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
        .foregroundColor(.white)
    }
}

extension Sidebar {
    fileprivate func badge(for t: Tool) -> Color? {
        switch t {
        case .mixer: return conn.mixer?.mic?.muted == true ? Theme.bad : nil
        case .transfer: return transfers.items.contains(where: { $0.state == .sending || $0.state == .queued }) ? Theme.accent : nil
        case .docs: return docs.incoming.isEmpty ? nil : Theme.accent
        case .time: return conn.timeSummary?.current != nil ? Theme.bad : nil
        default: return nil
        }
    }

    fileprivate func toolTile(_ t: Tool, badge: Color?) -> some View {
        Button {
            tool = (tool == t) ? nil : t
        } label: {
            VStack(spacing: 3) {
                Image(systemName: Symbols.valid(t.symbol) ?? "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                Text(t.title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(tool == t ? Theme.accent.opacity(0.9) : Theme.raised))
            .overlay(Circle().fill(badge ?? Color.clear).frame(width: 8, height: 8).padding(5), alignment: .topTrailing)
            .foregroundColor(.white)
        }
    }
}

private struct SidebarIconButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: Symbols.valid(symbol) ?? "square")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.accent.opacity(0.35) : Theme.raised))
                .foregroundColor(.white)
        }
    }
}

private struct StatusPill: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? Theme.ok : Theme.bad)
                .frame(width: 8, height: 8)
            Text(connected ? "Lidhur me USB" : "Pa lidhje")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill((connected ? Theme.ok : Theme.bad).opacity(0.15)))
    }
}

// MARK: - Waiting screen

private struct WaitingView: View {
    let connected: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: connected ? "checkmark.circle.fill" : (Symbols.valid("cable.connector") ?? "bolt.horizontal.circle"))
                .font(.system(size: 64, weight: .light))
                .foregroundColor(connected ? Theme.ok : Theme.accent)
            Text(connected ? "U lidh! Duke pritur profilet…" : "Lidh iPad-in me kabllo USB")
                .font(.system(size: 26, weight: .bold))
            if !connected {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Lidh iPad-in me PC-në me kabllo.")
                    step(2, "Në PC hap “Start USB Deck” (agjenti).")
                    step(3, "Mbaje këtë aplikacion të hapur – lidhet vetë.")
                }
                .padding(.top, 6)
            }
        }
        .foregroundColor(.white)
        .padding(40)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(n)")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .font(.system(size: 16))
                .foregroundColor(Theme.textDim)
        }
    }
}

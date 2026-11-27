import SwiftUI
import UIKit

/// "Folders": a drawer hidden on the right edge of the iPad, available from every screen.
struct FoldersDrawer: View {
    @EnvironmentObject var conn: Connection
    @State private var open = false

    var body: some View {
        EdgeDrawer(side: .trailing, size: 400, open: $open) { isOpen in
            SideHandle(symbol: "folder.fill", open: isOpen, tint: Theme.accent,
                       corners: [.topLeft, .bottomLeft], openSymbol: "chevron.right")
        } content: {
            FoldersPanel(onDone: { open = false })
        }
        .onChange(of: open) { v in if v { conn.requestPaths() } }
    }
}

/// The drawer's content.
struct FoldersPanel: View {
    @EnvironmentObject var conn: Connection
    let onDone: () -> Void
    @AppStorage("usbdeck.pathEnter") private var pressEnter = true
    @AppStorage("usbdeck.pathTapOpens") private var tapOpens = false
    @AppStorage("usbdeck.foldersPinned") private var pinned = false
    @State private var flashed: String?
    @State private var showExplorer = false
    @State private var confirmDelete: PathItem?

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundColor(Color(red: 0.35, green: 0.65, blue: 1))
                Text("Folders").font(.system(size: 22, weight: .bold))
                Spacer()
                Button { pinned.toggle() } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(pinned ? Theme.accent : .white)
                }
                Button { conn.requestPaths() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
                }
                Button {
                    conn.requestExplorerFolders()
                    showExplorer = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accent))
                }
            }

            Picker("", selection: $tapOpens) {
                Text("Vendos rrugën").tag(false)
                Text("Hap folderin").tag(true)
            }
            .pickerStyle(.segmented)

            if !tapOpens {
                Toggle(isOn: $pressEnter) {
                    Text("Shtyp Enter pas (në “Save As” të çon te folderi)")
                        .font(.system(size: 12)).foregroundColor(Theme.textDim)
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            }

            if conn.paths.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 40)).foregroundColor(Theme.textDim)
                    Text("Asnjë folder ende").font(.system(size: 17, weight: .bold))
                    Text("Shto me + (folderat e hapur në Explorer), nga editori në PC › 📁 Folders, ose në Explorer: kliko me të djathtën › Send to › Shto te Folders.")
                        .font(.system(size: 12)).foregroundColor(Theme.textDim)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(conn.paths) { item in tile(item) }
                    }
                    .padding(.bottom, 8)
                }
                Text(tapOpens ? "Prekja hap folderin në PC · ⌨︎ e vendos rrugën te fusha ku je"
                              : "Prekja e vendos rrugën te fusha ku je në PC · ↗ hap folderin")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            }
        }
        .padding(16)
        .foregroundColor(.white)
        .sheet(isPresented: $showExplorer) { ExplorerPicker(isPresented: $showExplorer).environmentObject(conn) }
        .alert(item: $confirmDelete) { item in
            Alert(title: Text("Të hiqet “\(item.name)”?"),
                  message: Text("Hiqet vetëm nga lista – folderi në PC nuk preket."),
                  primaryButton: .destructive(Text("Hiqe")) { conn.deletePath(item.id) },
                  secondaryButton: .cancel(Text("Anulo")))
        }
    }

    private func tile(_ item: PathItem) -> some View {
        let missing = item.exists == false
        return Button {
            flashed = item.id
            if tapOpens { conn.revealPath(item.id) } else { conn.insertPath(item.id, enter: pressEnter) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if flashed == item.id { flashed = nil } }
            if !pinned { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onDone() } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: missing ? "folder.badge.questionmark" : "folder.fill")
                    .font(.system(size: 26))
                    .foregroundColor(missing ? Theme.bad : Color(red: 0.35, green: 0.65, blue: 1))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textDim)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                // the "other" action, one tap away
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(flashed == item.id ? Theme.accent.opacity(0.35) : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(flashed == item.id ? Theme.accent : Theme.stroke, lineWidth: flashed == item.id ? 2 : 1))
            .scaleEffect(flashed == item.id ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: flashed)
            .foregroundColor(.white)
        }
        .overlay(
            Button {
                flashed = item.id
                if tapOpens { conn.insertPath(item.id, enter: pressEnter) } else { conn.revealPath(item.id) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if flashed == item.id { flashed = nil } }
                if !pinned { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onDone() } }
            } label: {
                Image(systemName: tapOpens ? "keyboard" : "arrow.up.forward.app")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .foregroundColor(.white)
            }
            .padding(.trailing, 12),
            alignment: .trailing
        )
        .contextMenu {
            Button { conn.insertPath(item.id, enter: !pressEnter) } label: {
                Label(pressEnter ? "Vendose pa Enter" : "Vendose me Enter", systemImage: "text.insert")
            }
            Button { conn.revealPath(item.id) } label: { Label("Hap folderin në PC", systemImage: "folder") }
            Button { conn.copyPath(item.id) } label: { Label("Kopjo në clipboard të PC-së", systemImage: "doc.on.doc") }
            Button { UIPasteboard.general.string = item.path } label: { Label("Kopjo në iPad", systemImage: "doc.on.clipboard") }
            Button { confirmDelete = item } label: { Label("Hiqe nga lista", systemImage: "trash") }
        }
    }
}

/// Folders currently open in File Explorer on the PC - tap one to save it as a path.
private struct ExplorerPicker: View {
    @EnvironmentObject var conn: Connection
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            Group {
                if let items = conn.explorerFolders {
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "macwindow").font(.system(size: 40)).foregroundColor(Theme.textDim)
                            Text("S'ka asnjë dosje të hapur në Explorer").font(.system(size: 16, weight: .bold))
                            Text("Hap dosjen e projektit në PC, pastaj prek ↻.").font(.system(size: 13)).foregroundColor(Theme.textDim)
                        }
                    } else {
                        List(items) { f in
                            Button {
                                conn.addPath(f.path, name: f.name)
                                isPresented = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundColor(Color(red: 0.35, green: 0.65, blue: 1))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).font(.system(size: 15, weight: .semibold))
                                        Text(f.path).font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                                    }
                                    Spacer()
                                    if items.first == f {
                                        Text("e fundit").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.accent)
                                    }
                                    Image(systemName: "plus.circle.fill").foregroundColor(Theme.accent)
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Po shikoj dosjet e hapura në Explorer…").font(.system(size: 14)).foregroundColor(Theme.textDim)
                    }
                }
            }
            .navigationTitle("Shto nga Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Mbyll") { isPresented = false } }
                ToolbarItem(placement: .primaryAction) {
                    Button { conn.requestExplorerFolders() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}

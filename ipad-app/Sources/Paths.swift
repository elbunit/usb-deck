import SwiftUI
import UIKit

/// "Rrugët": saved folder paths. A tap PASTES the path into the field that has focus on
/// the PC (Save As, export location, Explorer address bar...) - it doesn't open the folder.
struct PathsView: View {
    @EnvironmentObject var conn: Connection
    @AppStorage("usbdeck.pathEnter") private var pressEnter = true
    @State private var flashed: String?
    @State private var showExplorer = false
    @State private var confirmDelete: PathItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rrugët").font(.system(size: 22, weight: .bold))
                    Text("Kliko në PC te fusha (p.sh. “Save As”), pastaj prek rrugën këtu.")
                        .font(.system(size: 12)).foregroundColor(Theme.textDim)
                }
                Spacer()
                Toggle(isOn: $pressEnter) {
                    Text("Enter pas").font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                .fixedSize()
                Button {
                    conn.requestExplorerFolders()
                    showExplorer = true
                } label: {
                    Label("Nga Explorer", systemImage: "plus.rectangle.on.folder.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.accent))
                }
                Button { conn.requestPaths() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .semibold))
                }
            }

            if conn.paths.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "text.insert").font(.system(size: 44)).foregroundColor(Theme.textDim)
                    Text("Asnjë rrugë ende").font(.system(size: 18, weight: .bold))
                    Text("Shto nga: butoni “Nga Explorer” këtu · editori në PC › 📁 Rrugët · ose në Explorer: kliko me të djathtën një dosje › Send to › Shto si rrugë.")
                        .font(.system(size: 13)).foregroundColor(Theme.textDim)
                        .multilineTextAlignment(.center).frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(conn.paths) { item in tile(item) }
                    }
                    .padding(.bottom, 8)
                }
                Text(pressEnter
                     ? "“Enter pas” është ndezur: në “Save As” të çon direkt te dosja. Fike nëse do vetëm ta ngjitësh tekstin."
                     : "Vetëm e ngjit rrugën (pa Enter). Mbaj gishtin mbi një rrugë për më shumë.")
                    .font(.system(size: 11)).foregroundColor(Theme.textDim)
            }
        }
        .padding(16)
        .foregroundColor(.white)
        .onAppear { conn.requestPaths() }
        .sheet(isPresented: $showExplorer) { ExplorerPicker(isPresented: $showExplorer).environmentObject(conn) }
        .alert(item: $confirmDelete) { item in
            Alert(title: Text("Të fshihet “\(item.name)”?"),
                  message: Text("Hiqet vetëm nga lista – dosja në PC nuk preket."),
                  primaryButton: .destructive(Text("Fshi")) { conn.deletePath(item.id) },
                  secondaryButton: .cancel(Text("Anulo")))
        }
    }

    private func tile(_ item: PathItem) -> some View {
        let missing = item.exists == false
        return Button {
            flashed = item.id
            conn.insertPath(item.id, enter: pressEnter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if flashed == item.id { flashed = nil } }
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
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(flashed == item.id ? Theme.accent.opacity(0.35) : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(flashed == item.id ? Theme.accent : Theme.stroke, lineWidth: flashed == item.id ? 2 : 1))
            .scaleEffect(flashed == item.id ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: flashed)
            .foregroundColor(.white)
        }
        .contextMenu {
            Button { conn.insertPath(item.id, enter: !pressEnter) } label: {
                Label(pressEnter ? "Vendose pa Enter" : "Vendose me Enter", systemImage: "text.insert")
            }
            Button { conn.revealPath(item.id) } label: { Label("Hap dosjen në PC", systemImage: "folder") }
            Button { conn.copyPath(item.id) } label: { Label("Kopjo në clipboard të PC-së", systemImage: "doc.on.doc") }
            Button { UIPasteboard.general.string = item.path } label: { Label("Kopjo në iPad", systemImage: "doc.on.clipboard") }
            Button { confirmDelete = item } label: { Label("Fshi nga lista", systemImage: "trash") }
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

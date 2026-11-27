import SwiftUI

/// Live link with Premiere Pro through the "USB Deck" CEP panel.
final class PremiereModel: ObservableObject {
    @Published var connected = false
    @Published var installed = false
    @Published var project = ""
    @Published var sequences: [PproSequence] = []
    @Published var sequence: PproSeqInfo?
    @Published var markers: [PproMarker] = []
    @Published var seconds: Double = 0
    @Published var presets: [PproPreset] = []

    func apply(_ m: PproStateMessage) {
        connected = m.connected
        if !m.connected { return }
        project = m.project ?? ""
        sequences = m.sequences ?? []
        sequence = m.sequence
        markers = (m.markers ?? []).sorted { $0.t < $1.t }
    }

    func applyStatus(_ m: PproStatusMessage) {
        installed = m.installed
        presets = m.presets
        if !m.connected { connected = false }
    }

    var fps: Double { sequence?.fps ?? 25 }

    func timecode(_ s: Double) -> String {
        let nominal = max(1, Int(fps.rounded()))
        let total = Int(((s + (sequence?.zero ?? 0)) * fps + 0.0001).rounded(.down))
        let f = total % nominal
        let secs = total / nominal
        return String(format: "%02d:%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60, f)
    }
}

/// Premiere's marker colours, in index order.
let premiereMarkerColors: [(String, Color)] = [
    ("Jeshile", Color(red: 0.30, green: 0.78, blue: 0.33)),
    ("E kuqe", Color(red: 0.92, green: 0.26, blue: 0.24)),
    ("Vjollcë", Color(red: 0.78, green: 0.35, blue: 0.85)),
    ("Portokalli", Color(red: 0.98, green: 0.58, blue: 0.16)),
    ("E verdhë", Color(red: 0.97, green: 0.85, blue: 0.20)),
    ("E bardhë", Color(red: 0.92, green: 0.92, blue: 0.92)),
    ("Blu", Color(red: 0.25, green: 0.50, blue: 0.98)),
    ("Cyan", Color(red: 0.20, green: 0.82, blue: 0.86)),
]

struct PremiereView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var pp: PremiereModel
    @State private var color = 1
    @State private var name = ""
    @State private var comment = ""
    @AppStorage("usbdeck.pproPreset") private var presetPath = ""
    @AppStorage("usbdeck.pproRange") private var range = 0
    @AppStorage("usbdeck.pproStart") private var startNow = true
    @AppStorage("usbdeck.pproOrganizeDeep") private var organizeDeep = false
    @State private var confirmOrganize = false

    var body: some View {
        Group {
            if pp.connected {
                connectedView
            } else {
                setupView
            }
        }
        .foregroundColor(.white)
        .onAppear { conn.send(["type": "ppro_status_request"]) }
    }

    // MARK: Not connected

    private var setupView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "film").font(.system(size: 50, weight: .light)).foregroundColor(Theme.accent)
            Text("Lidhja e thellë me Premiere Pro").font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                step(1, pp.installed ? "Paneli është instaluar ✓" : "Instalo panelin “USB Deck” në Premiere (një herë).")
                step(2, "Rinis Premiere-n.")
                step(3, "Në Premiere: Window › Extensions › USB Deck (lëre të hapur, mund ta bësh të vogël).")
            }
            .frame(maxWidth: 480, alignment: .leading)
            HStack(spacing: 10) {
                Button {
                    conn.send(["type": "ppro_install"])
                } label: {
                    Text(pp.installed ? "Riinstalo panelin" : "Instalo panelin").font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.accent))
                }
                Button("Kontrollo prapë") { conn.send(["type": "ppro_status_request"]) }
                    .font(.system(size: 14))
            }
            .disabled(!conn.connected)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold))
                .frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
            Text(text).font(.system(size: 14)).foregroundColor(Theme.textDim)
        }
    }

    // MARK: Connected

    private var connectedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Timecode + sequence
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.ok).frame(width: 8, height: 8)
                        Text(pp.project).font(.system(size: 12)).foregroundColor(Theme.textDim).lineLimit(1)
                        Spacer()
                        Menu {
                            ForEach(pp.sequences) { s in
                                Button(s.name) { conn.send(["type": "ppro_open_sequence", "id": s.id]) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.stack")
                                Text(pp.sequence?.name ?? "Pa sekuencë").lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.raised))
                        }
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Text(pp.timecode(pp.seconds))
                            .font(.system(size: 46, weight: .bold, design: .monospaced))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Spacer()
                        navButton("backward.end.fill") { jump(previous: true) }
                        navButton("forward.end.fill") { jump(previous: false) }
                    }
                    Text(String(format: "%.2f fps", pp.fps)).font(.system(size: 11)).foregroundColor(Theme.textDim)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))

                // New marker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Marker i ri te playhead-i").font(.system(size: 15, weight: .bold))
                    HStack(spacing: 8) {
                        ForEach(0..<premiereMarkerColors.count, id: \.self) { i in
                            Button { color = i } label: {
                                Circle().fill(premiereMarkerColors[i].1)
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: color == i ? 3 : 0))
                            }
                        }
                        Spacer()
                        Button {
                            addMarker(quick: true)
                        } label: {
                            Label("I shpejtë", systemImage: "bolt.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(premiereMarkerColors[color].1.opacity(0.35)))
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Emri (p.sh. Ndrysho muzikën)", text: $name)
                            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                        TextField("Shënim / koment", text: $comment)
                            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                        Button { addMarker(quick: false) } label: {
                            Image(systemName: "plus").font(.system(size: 18, weight: .bold))
                                .frame(width: 44, height: 40)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))

                // Markers list
                VStack(alignment: .leading, spacing: 8) {
                    Text("Markerat (\(pp.markers.count))").font(.system(size: 15, weight: .bold))
                    if pp.markers.isEmpty {
                        Text("Ende pa markera në këtë sekuencë.").font(.system(size: 13)).foregroundColor(Theme.textDim)
                    }
                    ForEach(pp.markers) { m in
                        Button {
                            conn.send(["type": "ppro_goto", "seconds": m.t])
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(premiereMarkerColors[min(max(m.color ?? 0, 0), 7)].1)
                                    .frame(width: 6, height: 30)
                                Text(pp.timecode(m.t)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((m.name ?? "").isEmpty ? "Marker" : (m.name ?? "")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    if let c = m.comment, !c.isEmpty {
                                        Text(c).font(.system(size: 12)).foregroundColor(Theme.textDim).lineLimit(2)
                                    }
                                }
                                Spacer()
                                if abs(m.t - pp.seconds) < 0.05 {
                                    Image(systemName: "play.fill").foregroundColor(Theme.accent)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                            .foregroundColor(.white)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                conn.send(["type": "ppro_delete_marker", "guid": m.guid])
                            } label: { Label("Fshi markerin", systemImage: "trash") }
                        }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))

                // Organize project
                VStack(alignment: .leading, spacing: 10) {
                    Text("Rregullo projektin").font(.system(size: 15, weight: .bold))
                    Text("Krijon bin-et 01 Sekuenca · 02 Video · 03 Audio · 04 Muzikë · 05 Foto · 06 Grafikë · 07 Elemente · 08 Të tjera dhe vendos çdo skedar te bin-i i duhur. Projekti ruhet automatikisht para se të fillojë.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textDim)
                    Toggle(isOn: $organizeDeep) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Përfshi edhe skedarët brenda bin-eve të mia").font(.system(size: 13))
                            Text("Bin-et e tua që mbeten bosh fshihen. “Logot” nuk preket.")
                                .font(.system(size: 11)).foregroundColor(Theme.textDim)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                    Button {
                        confirmOrganize = true
                    } label: {
                        Label("Rregullo tani", systemImage: "folder.badge.gearshape")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
                    }
                    .alert(isPresented: $confirmOrganize) {
                        Alert(title: Text("Të rregullohet projekti?"),
                              message: Text(organizeDeep
                                            ? "Të gjithë skedarët, edhe ata brenda bin-eve të tua, do të zhvendosen sipas llojit."
                                            : "Skedarët që janë jashtë bin-eve do të zhvendosen sipas llojit."),
                              primaryButton: .default(Text("Rregullo")) {
                                  conn.send(["type": "ppro_organize", "deep": organizeDeep])
                              },
                              secondaryButton: .cancel(Text("Anulo")))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))

                // Export
                VStack(alignment: .leading, spacing: 10) {
                    Text("Eksport te Media Encoder").font(.system(size: 15, weight: .bold))
                    Menu {
                        ForEach(pp.presets) { p in
                            Button {
                                presetPath = p.path
                            } label: {
                                Label(p.name, systemImage: p.user == true ? "person.fill" : "film")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                            Text(pp.presets.first { $0.path == presetPath }?.name ?? "Zgjidh preset-in…").lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                    }
                    Picker("", selection: $range) {
                        Text("Gjithë sekuencën").tag(0)
                        Text("In → Out").tag(1)
                        Text("Work Area").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $startNow) {
                        Text("Nise render-in menjëherë (përndryshe vetëm shtohet në radhë)").font(.system(size: 13))
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                    Button {
                        conn.send(["type": "ppro_export", "preset": presetPath, "range": range, "start": startNow])
                    } label: {
                        Label("Eksporto “\(pp.sequence?.name ?? "")”", systemImage: "paperplane.fill")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 12).fill(presetPath.isEmpty ? Theme.raised : Theme.ok))
                    }
                    .disabled(presetPath.isEmpty || pp.sequence == nil)
                    Text("Kur mbaron, del njoftimi fullscreen “Render-i përfundoi”.")
                        .font(.system(size: 11)).foregroundColor(Theme.textDim)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            }
            .padding(16)
        }
    }

    private func navButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold))
                .frame(width: 52, height: 46)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
        }
    }

    private func jump(previous: Bool) {
        let now = pp.seconds
        let target: PproMarker?
        if previous {
            target = pp.markers.last(where: { $0.t < now - 0.04 })
        } else {
            target = pp.markers.first(where: { $0.t > now + 0.04 })
        }
        if let t = target { conn.send(["type": "ppro_goto", "seconds": t.t]) }
    }

    private func addMarker(quick: Bool) {
        var msg: [String: Any] = ["type": "ppro_marker", "color": color]
        msg["name"] = quick ? "" : name
        msg["comment"] = quick ? "" : comment
        conn.send(msg)
        if !quick {
            name = ""
            comment = ""
        }
    }
}

import Combine
import SwiftUI

// MARK: - Projects (new + recent + backups)

struct ProjectsView: View {
    @EnvironmentObject var conn: Connection
    @State private var client = ""
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Projektet").font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button { conn.requestProjects() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .semibold))
                    }
                }

                // New project
                VStack(alignment: .leading, spacing: 10) {
                    Label("Projekt i ri", systemImage: "folder.badge.plus")
                        .font(.system(size: 16, weight: .bold))
                    HStack(spacing: 10) {
                        field("Klienti / brendi", $client)
                        field("Emri i projektit", $name)
                        Button {
                            conn.newProject(client: client, name: name)
                            client = ""
                            name = ""
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { conn.requestProjects() }
                        } label: {
                            Text("Krijo").font(.system(size: 15, weight: .bold))
                                .padding(.horizontal, 22).padding(.vertical, 11)
                                .background(Capsule().fill(Theme.accent))
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !conn.connected)
                    }
                    if let p = conn.projects {
                        Text(templateLine(p))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textDim)
                            .lineLimit(2)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))

                // Recent
                HStack {
                    Text("Të fundit").font(.system(size: 16, weight: .bold))
                    Spacer()
                    if conn.projects?.backup == true {
                        Label("Backup automatik: ON", systemImage: "externaldrive.badge.checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.ok)
                    }
                }
                let recent = conn.projects?.recent ?? []
                if recent.isEmpty {
                    Text("Nuk u gjet asnjë .prproj / .aep. Shto dosjet e projekteve te editori në PC → ⚙ Cilësimet → Projektet.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textDim)
                } else {
                    ForEach(recent) { p in
                        ProjectRow(project: p,
                                   onOpen: { conn.openProject(p.path) },
                                   onReveal: { conn.revealProject(p.path, backups: false) },
                                   onBackups: { conn.revealProject(p.path, backups: true) })
                    }
                }
            }
            .padding(16)
        }
        .foregroundColor(.white)
        .onAppear { conn.requestProjects() }
    }

    private func templateLine(_ p: ProjectsMessage) -> String {
        let parts: [String] = Array((p.template ?? []).prefix(6))
        let root: String = p.root ?? ""
        return root + "  →  " + parts.joined(separator: " · ")
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
    }
}

private struct ProjectRow: View {
    let project: ProjectItem
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onBackups: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(project.ext == "aep" ? "Ae" : "Pr")
                .font(.system(size: 15, weight: .heavy))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(project.ext == "aep" ? Color(red: 0.2, green: 0.1, blue: 0.4) : Color(red: 0.12, green: 0.1, blue: 0.35)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(project.ext == "aep"
                    ? Color(red: 0.6, green: 0.55, blue: 1) : Color(red: 0.6, green: 0.6, blue: 1), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text("Ndryshuar \(project.modified)")
                    if let b = project.backup { Text("· 💾 \(b)") }
                }
                .font(.system(size: 11))
                .foregroundColor(Theme.textDim)
            }
            Spacer()
            iconButton("clock.arrow.circlepath", onBackups)
            iconButton("folder", onReveal)
            Button(action: onOpen) {
                Text("Hap").font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundColor(.white)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private func iconButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Time tracking

struct TimeView: View {
    @EnvironmentObject var conn: Connection
    @State private var range = "today"
    private let refresh = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Koha e punës").font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("", selection: $range) {
                    Text("Sot").tag("today")
                    Text("Java").tag("week")
                    Text("Muaji").tag("month")
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            let summary = conn.timeSummary
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(format(summary?.total ?? 0))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                if let cur = summary?.current {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.bad).frame(width: 8, height: 8)
                        Text("Po matet: \(cur.project) · \(cur.app)").lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.bad.opacity(0.15)))
                }
            }

            let items = summary?.items ?? []
            let maxSecs = max(items.first?.seconds ?? 1, 1)
            if items.isEmpty {
                Text("Ende pa kohë të matur. Koha matet vetë kur punon në Premiere, After Effects, Resolve, Photoshop… (pauzohet kur s'prek mausin/tastierën).")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textDim)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(items) { e in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(e.project).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(format(e.seconds)).font(.system(size: 15, weight: .bold, design: .rounded))
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.raised)
                                        Capsule().fill(Theme.accent)
                                            .frame(width: max(6, geo.size.width * CGFloat(e.seconds) / CGFloat(maxSecs)))
                                    }
                                }
                                .frame(height: 8)
                                Text(e.apps.map { "\($0.app) \(format($0.seconds))" }.joined(separator: " · "))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textDim)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                        }
                    }
                }
            }
        }
        .padding(16)
        .foregroundColor(.white)
        .onAppear { conn.requestTime(range) }
        .onChange(of: range) { conn.requestTime($0) }
        .onReceive(refresh) { _ in conn.requestTime(range) }
    }

    private func format(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)o \(m)m" : "\(m)m"
    }
}

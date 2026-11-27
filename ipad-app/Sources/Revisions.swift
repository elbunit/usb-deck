import SwiftUI
import UIKit

// MARK: - Model + storage

struct RevisionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var seconds: Double?
    var frames: Int = 0
    var label: String?        // timecode as the client wrote it, e.g. "0:45"
    var text: String
    var done = false
}

struct RevisionList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var items: [RevisionItem]

    var doneCount: Int { items.filter { $0.done }.count }
}

/// Client revision lists, saved on the iPad.
final class RevisionStore: ObservableObject {
    @Published var lists: [RevisionList] = [] { didSet { save() } }
    private let key = "usbdeck.revisions.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RevisionList].self, from: data) {
            lists = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Parser

enum FeedbackParser {
    private static let timecode = try! NSRegularExpression(
        pattern: #"(?<![\d:])(\d{1,2}):(\d{2})(?::(\d{2}))?(?::(\d{2}))?(?![\d:])"#)
    private static let bullet = try! NSRegularExpression(
        pattern: #"^\s*(?:[-–—•*·>]+|\d{1,2}[.)])\s+"#)

    /// One item per non-empty line. A timecode anywhere in the line is picked up:
    /// m:ss, mm:ss, h:mm:ss or hh:mm:ss:ff.
    static func parse(_ text: String) -> [RevisionItem] {
        var out: [RevisionItem] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            line = bullet.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")

            var item = RevisionItem(text: line)
            let range = NSRange(line.startIndex..., in: line)
            if let m = timecode.firstMatch(in: line, range: range) {
                func group(_ i: Int) -> Int? {
                    guard let r = Range(m.range(at: i), in: line) else { return nil }
                    return Int(line[r])
                }
                let a = group(1) ?? 0, b = group(2) ?? 0
                if let c = group(3) {
                    item.seconds = Double(a * 3600 + b * 60 + c)
                    item.frames = group(4) ?? 0
                } else {
                    item.seconds = Double(a * 60 + b)
                }
                if let r = Range(m.range, in: line) {
                    item.label = String(line[r])
                    var rest = line
                    rest.removeSubrange(r)
                    let junk = CharacterSet(charactersIn: " \t-–—:.,;)]}>([{@|").union(.whitespaces)
                    item.text = rest.trimmingCharacters(in: junk)
                        .replacingOccurrences(of: "  ", with: " ")
                    if item.text.isEmpty { item.text = "(pa përshkrim)" }
                }
            }
            out.append(item)
        }
        return out
    }
}

// MARK: - Screen

struct RevisionsView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var store: RevisionStore
    @State private var selected: UUID?
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteIntoCurrent = false
    @State private var newLine = ""
    @State private var lastJumped: UUID?
    @State private var loadingPC = false

    private var currentIndex: Int? {
        guard let id = selected ?? store.lists.first?.id else { return nil }
        return store.lists.firstIndex { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            listsColumn
                .frame(width: 210)
                .background(Theme.panel.opacity(0.6))
            Divider().background(Theme.stroke)
            if let i = currentIndex {
                detail(i)
            } else {
                emptyState
            }
        }
        .foregroundColor(.white)
        .sheet(isPresented: $showPaste) { pasteSheet }
    }

    // MARK: Lists

    private var listsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Korrigjimet")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 14)
            Button {
                pasteIntoCurrent = false
                pasteText = ""
                showPaste = true
            } label: {
                Label("Listë e re", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.lists) { list in
                        Button {
                            selected = list.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(list.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                HStack(spacing: 6) {
                                    ProgressView(value: list.items.isEmpty ? 0 : Double(list.doneCount) / Double(list.items.count))
                                        .tint(list.doneCount == list.items.count && !list.items.isEmpty ? Theme.ok : Theme.accent)
                                    Text("\(list.doneCount)/\(list.items.count)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Theme.textDim)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(list.id == (selected ?? store.lists.first?.id) ? Theme.raised : Color.clear))
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.lists.removeAll { $0.id == list.id }
                                if selected == list.id { selected = nil }
                            } label: { Label("Fshi listën", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 46))
                .foregroundColor(Theme.textDim)
            Text("Ngjit feedback-un e klientit")
                .font(.system(size: 20, weight: .bold))
            Text("p.sh.  0:45 – hiq logon  ·  1:12 muzika më e ulët\nÇdo rresht bëhet një detyrë; prek kohën për të shkuar aty në timeline.")
                .font(.system(size: 14))
                .foregroundColor(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Detail

    private func detail(_ i: Int) -> some View {
        let list = store.lists[i]
        let nextUndone = list.items.first { !$0.done && $0.seconds != nil }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Emri i listës", text: Binding(
                    get: { store.lists.indices.contains(i) ? store.lists[i].name : "" },
                    set: { if store.lists.indices.contains(i) { store.lists[i].name = $0 } }))
                    .font(.system(size: 20, weight: .bold))
                Text("\(list.doneCount)/\(list.items.count) gati")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(list.doneCount == list.items.count && !list.items.isEmpty ? Theme.ok : Theme.textDim)
            }

            HStack(spacing: 8) {
                if let next = nextUndone {
                    Button { jump(next) } label: {
                        Label("Tjetra: \(next.label ?? "")", systemImage: "forward.end.fill")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.accent))
                    }
                }
                Button {
                    pasteIntoCurrent = true
                    pasteText = ""
                    showPaste = true
                } label: {
                    Label("Shto", systemImage: "text.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.raised))
                }
                Spacer()
                Menu {
                    Button { setAll(i, done: false) } label: { Label("Hiq të gjitha ✓", systemImage: "arrow.uturn.backward") }
                    Button { copyList(list) } label: { Label("Kopjo listën", systemImage: "doc.on.doc") }
                    Button(role: .destructive) {
                        store.lists.remove(at: i)
                        selected = nil
                    } label: { Label("Fshi listën", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22))
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(list.items) { item in
                        RevisionRow(item: item,
                                    highlighted: item.id == lastJumped,
                                    onToggle: { toggle(i, item.id) },
                                    onJump: { jump(item) },
                                    onDelete: { delete(i, item.id) })
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Shto një korrigjim… (p.sh. 1:05 ndrysho tekstin)", text: $newLine, onCommit: { addLine(i) })
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                Button { addLine(i) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 28))
                }
                .disabled(newLine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Paste sheet

    private var pasteSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        loadingPC = true
                        conn.requestPCClipboard { text in
                            loadingPC = false
                            if !text.isEmpty { pasteText = text }
                        }
                    } label: {
                        Label(loadingPC ? "Duke marrë…" : "Ngjit nga PC-ja", systemImage: "desktopcomputer")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.accent))
                            .foregroundColor(.white)
                    }
                    .disabled(!conn.connected)
                    Button {
                        if let s = UIPasteboard.general.string { pasteText = s }
                    } label: {
                        Label("Ngjit nga iPad-i", systemImage: "doc.on.clipboard")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.raised))
                            .foregroundColor(.white)
                    }
                }
                Text("Kopjo email-in/mesazhin e klientit në PC (Ctrl+C) dhe prek “Ngjit nga PC-ja”. Çdo rresht bëhet një detyrë.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textDim)
                TextEditor(text: $pasteText)
                    .font(.system(size: 15, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                let preview = FeedbackParser.parse(pasteText)
                Text("\(preview.count) korrigjime · \(preview.filter { $0.seconds != nil }.count) me kohë")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textDim)
            }
            .padding()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(pasteIntoCurrent ? "Shto korrigjime" : "Listë e re")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anulo") { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ruaj") { commitPaste() }
                        .disabled(FeedbackParser.parse(pasteText).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    // MARK: Actions

    private func commitPaste() {
        let items = FeedbackParser.parse(pasteText)
        guard !items.isEmpty else { return }
        if pasteIntoCurrent, let i = currentIndex {
            store.lists[i].items.append(contentsOf: items)
        } else {
            let f = DateFormatter()
            f.dateFormat = "d MMM HH:mm"
            let list = RevisionList(name: "Korrigjime \(f.string(from: Date()))", items: items)
            store.lists.insert(list, at: 0)
            selected = list.id
        }
        showPaste = false
    }

    private func addLine(_ i: Int) {
        let items = FeedbackParser.parse(newLine)
        guard !items.isEmpty, store.lists.indices.contains(i) else { return }
        store.lists[i].items.append(contentsOf: items)
        newLine = ""
    }

    private func toggle(_ i: Int, _ id: UUID) {
        guard store.lists.indices.contains(i), let j = store.lists[i].items.firstIndex(where: { $0.id == id }) else { return }
        store.lists[i].items[j].done.toggle()
    }

    private func delete(_ i: Int, _ id: UUID) {
        guard store.lists.indices.contains(i) else { return }
        store.lists[i].items.removeAll { $0.id == id }
    }

    private func setAll(_ i: Int, done: Bool) {
        guard store.lists.indices.contains(i) else { return }
        for j in store.lists[i].items.indices { store.lists[i].items[j].done = done }
    }

    private func jump(_ item: RevisionItem) {
        guard let s = item.seconds else { return }
        lastJumped = item.id
        conn.goTo(seconds: s, frames: item.frames)
    }

    private func copyList(_ list: RevisionList) {
        UIPasteboard.general.string = list.items
            .map { ($0.done ? "✓ " : "☐ ") + ($0.label.map { $0 + " " } ?? "") + $0.text }
            .joined(separator: "\n")
        conn.showToast("Lista u kopjua")
    }
}

private struct RevisionRow: View {
    let item: RevisionItem
    let highlighted: Bool
    let onToggle: () -> Void
    let onJump: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundColor(item.done ? Theme.ok : Theme.textDim)
            }
            if let label = item.label {
                Button(action: onJump) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        Text(label).font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(highlighted ? Theme.accent : Theme.accent.opacity(0.25)))
                    .foregroundColor(.white)
                }
            }
            Text(item.text)
                .font(.system(size: 15))
                .strikethrough(item.done, color: Theme.textDim)
                .foregroundColor(item.done ? Theme.textDim : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(highlighted ? Theme.accent.opacity(0.12) : Theme.panel))
        .contextMenu {
            Button(role: .destructive, action: onDelete) { Label("Fshi", systemImage: "trash") }
        }
    }
}

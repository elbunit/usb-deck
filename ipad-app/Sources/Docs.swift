import QuickLook
import SwiftUI
import UIKit

/// Documents sent from the PC (PDF, images, videos, Office files...), kept on the iPad.
/// begin/chunk/end/abortAll are called on the connection queue.
final class DocStore: ObservableObject {
    struct Doc: Identifiable, Hashable {
        let url: URL
        let date: Date
        let size: Int64
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    struct Incoming: Identifiable {
        let id: String
        let name: String
        let size: Int64
        var got: Int64
        var progress: Double { size > 0 ? min(Double(got) / Double(size), 1) : 0 }
    }

    @Published var docs: [Doc] = []
    @Published var incoming: [Incoming] = []
    @Published var newest: URL?

    private var open: [String: (handle: FileHandle, temp: URL, name: String, got: Int64, lastUI: Date)] = [:]

    let folder: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dokumente", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let list = urls.filter { $0.pathExtension != "part" }.map { url -> Doc in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Doc(url: url, date: v?.contentModificationDate ?? Date(), size: Int64(v?.fileSize ?? 0))
        }
        let sorted = list.sorted { $0.date > $1.date }
        if Thread.isMainThread {
            docs = sorted
        } else {
            DispatchQueue.main.async { self.docs = sorted }
        }
    }

    // MARK: Receiving (connection queue)

    func begin(id: String, name: String, size: Int64) {
        let temp = folder.appendingPathComponent(UUID().uuidString + ".part")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return }
        open[id] = (handle, temp, name, 0, Date())
        DispatchQueue.main.async {
            self.incoming.append(Incoming(id: id, name: name, size: size, got: 0))
        }
    }

    func chunk(id: String, base64: String) {
        guard var entry = open[id], let data = Data(base64Encoded: base64) else { return }
        entry.handle.write(data)
        entry.got += Int64(data.count)
        let now = Date()
        let refresh = now.timeIntervalSince(entry.lastUI) > 0.15
        if refresh { entry.lastUI = now }
        open[id] = entry
        if refresh {
            let got = entry.got
            DispatchQueue.main.async {
                if let i = self.incoming.firstIndex(where: { $0.id == id }) { self.incoming[i].got = got }
            }
        }
    }

    /// Returns the saved file name.
    func end(id: String) -> String? {
        guard let entry = open.removeValue(forKey: id) else { return nil }
        try? entry.handle.close()
        let dest = uniqueURL(for: entry.name)
        do {
            try FileManager.default.moveItem(at: entry.temp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: entry.temp)
            DispatchQueue.main.async { self.incoming.removeAll { $0.id == id } }
            return nil
        }
        DispatchQueue.main.async {
            self.incoming.removeAll { $0.id == id }
            self.reload()
            self.newest = dest
        }
        return dest.lastPathComponent
    }

    func abortAll() {
        for (_, entry) in open {
            try? entry.handle.close()
            try? FileManager.default.removeItem(at: entry.temp)
        }
        open.removeAll()
        DispatchQueue.main.async { self.incoming.removeAll() }
    }

    // MARK: Managing

    func delete(_ doc: Doc) {
        try? FileManager.default.removeItem(at: doc.url)
        reload()
    }

    private func uniqueURL(for name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "_")
        var url = folder.appendingPathComponent(clean)
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }
}

// MARK: - QuickLook

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Screen

struct DocsView: View {
    @EnvironmentObject var store: DocStore
    @State private var selected: URL?
    @State private var showList = true

    private var current: URL? { selected ?? store.docs.first?.url }

    var body: some View {
        HStack(spacing: 0) {
            if showList {
                list
                    .frame(width: 240)
                    .background(Theme.panel.opacity(0.6))
                Divider().background(Theme.stroke)
            }
            ZStack(alignment: .topLeading) {
                if let url = current, store.docs.contains(where: { $0.url == url }) {
                    QuickLookView(url: url)
                        .id(url)
                } else {
                    empty
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showList.toggle() }
                } label: {
                    Image(systemName: showList ? "sidebar.left" : "list.bullet")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .foregroundColor(.white)
                }
                .padding(10)
            }
        }
        .foregroundColor(.white)
        .onChange(of: store.newest) { url in
            if let url = url { selected = url }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dokumentet")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 14)
            ForEach(store.incoming) { inc in
                VStack(alignment: .leading, spacing: 4) {
                    Text(inc.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    ProgressView(value: inc.progress).tint(Theme.accent)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.docs) { doc in
                        Button {
                            selected = doc.url
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(doc.url.pathExtension))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: doc.size, countStyle: .file))
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textDim)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(doc.url == current ? Theme.raised : Color.clear))
                            .foregroundColor(.white)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                if selected == doc.url { selected = nil }
                                store.delete(doc)
                            } label: { Label("Fshi nga iPad-i", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 46))
                .foregroundColor(Theme.textDim)
            Text("Asnjë dokument ende")
                .font(.system(size: 20, weight: .bold))
            Text("Nga PC-ja: te editori kliko “📄 Dërgo te iPad”, ose kliko me të djathtën një skedar → Send to → Dergo te iPad.\nPDF, foto, video, Word, Excel – storyboard, skript, brief.")
                .font(.system(size: 14))
                .foregroundColor(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tif", "tiff": return "photo"
        case "mp4", "mov", "m4v": return "film"
        case "doc", "docx", "txt", "rtf", "pages": return "doc.text"
        case "xls", "xlsx", "csv", "numbers": return "tablecells"
        default: return "doc"
        }
    }
}

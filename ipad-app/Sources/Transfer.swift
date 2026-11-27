import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Transfer manager

/// Sends files from the iPad to the PC over the USB link, one at a time,
/// in 512 KB chunks. Each chunk is sent only after the previous one left
/// the device, so memory stays low even for multi-GB videos.
final class TransferManager: ObservableObject {
    enum State: Equatable { case preparing, queued, sending, waiting, done, failed }

    struct Item: Identifiable, Equatable {
        let id: String
        var name: String
        var size: Int64
        var sent: Int64
        var state: State
        var localURL: URL?
        var savedPath: String?
        var error: String?

        var progress: Double { size > 0 ? min(Double(sent) / Double(size), 1) : 0 }
    }

    @Published var items: [Item] = []
    weak var conn: Connection?

    private let io = DispatchQueue(label: "usbdeck.transfer")
    private var busy = false
    private static let chunkSize = 512 * 1024

    private var tempDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usbdeck-out", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var hasFinished: Bool { items.contains { $0.state == .done || $0.state == .failed } }

    // MARK: Adding files

    func addFromPhotos(_ results: [PHPickerResult], convertHEIC: Bool) {
        for result in results {
            let id = UUID().uuidString
            let provider = result.itemProvider
            let base = ((provider.suggestedName ?? "iPad") as NSString).deletingPathExtension
            items.append(Item(id: id, name: base, size: 0, sent: 0, state: .preparing))

            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
                    self?.stage(id: id, source: url, baseName: base, convertHEIC: false)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
                    self?.stage(id: id, source: url, baseName: base, convertHEIC: convertHEIC)
                }
            } else {
                failed(id: id, error: "Lloj skedari i pambështetur")
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let id = UUID().uuidString
            let base = url.deletingPathExtension().lastPathComponent
            items.append(Item(id: id, name: url.lastPathComponent, size: 0, sent: 0, state: .preparing))
            io.async { [weak self] in
                let access = url.startAccessingSecurityScopedResource()
                self?.stage(id: id, source: url, baseName: base, convertHEIC: false)
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    /// Copies the picked file into our temp folder (the system deletes its copy after the callback).
    private func stage(id: String, source: URL?, baseName: String, convertHEIC: Bool) {
        guard let source = source else {
            DispatchQueue.main.async { self.failed(id: id, error: "Skedari nuk u lexua") }
            return
        }
        var ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension
        let fm = FileManager.default
        var dest = tempDir.appendingPathComponent(id).appendingPathExtension(ext)
        do {
            let lower = ext.lowercased()
            if convertHEIC && (lower == "heic" || lower == "heif"),
               let image = UIImage(contentsOfFile: source.path),
               let jpeg = image.jpegData(compressionQuality: 0.95) {
                ext = "jpg"
                dest = tempDir.appendingPathComponent(id).appendingPathExtension(ext)
                try jpeg.write(to: dest)
            } else {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
            }
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            let name = baseName + "." + ext
            DispatchQueue.main.async {
                guard let i = self.index(id) else { return }
                self.items[i].name = name
                self.items[i].size = size
                self.items[i].localURL = dest
                self.items[i].state = .queued
                self.pump()
            }
        } catch {
            DispatchQueue.main.async { self.failed(id: id, error: error.localizedDescription) }
        }
    }

    // MARK: Sending

    func pump() {
        guard !busy, conn?.connected == true,
              let i = items.firstIndex(where: { $0.state == .queued }),
              let url = items[i].localURL else { return }
        busy = true
        items[i].state = .sending
        items[i].sent = 0
        let item = items[i]
        io.async { [weak self] in self?.start(item: item, url: url) }
    }

    private func start(item: Item, url: URL) {
        guard let conn = conn, let handle = try? FileHandle(forReadingFrom: url) else {
            DispatchQueue.main.async {
                self.failed(id: item.id, error: "Skedari nuk u hap")
                self.busy = false
                self.pump()
            }
            return
        }
        conn.send(["type": "file_begin", "id": item.id, "name": item.name, "size": item.size]) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.io.async { self.sendNextChunk(id: item.id, handle: handle, sent: 0) }
            } else {
                try? handle.close()
                self.finishSending(id: item.id, error: "Lidhja u ndërpre")
            }
        }
    }

    private func sendNextChunk(id: String, handle: FileHandle, sent: Int64) {
        guard let conn = conn else {
            try? handle.close()
            finishSending(id: id, error: "Lidhja u ndërpre")
            return
        }
        let data = handle.readData(ofLength: Self.chunkSize)
        if data.isEmpty {
            try? handle.close()
            conn.send(["type": "file_end", "id": id]) { [weak self] ok in
                self?.finishSending(id: id, error: ok ? nil : "Lidhja u ndërpre")
            }
            return
        }
        let total = sent + Int64(data.count)
        conn.send(["type": "file_chunk", "id": id, "data": data.base64EncodedString()]) { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                try? handle.close()
                self.finishSending(id: id, error: "Lidhja u ndërpre")
                return
            }
            DispatchQueue.main.async {
                if let i = self.index(id) { self.items[i].sent = total }
            }
            self.io.async { self.sendNextChunk(id: id, handle: handle, sent: total) }
        }
    }

    private func finishSending(id: String, error: String?) {
        DispatchQueue.main.async {
            if let error = error {
                self.failed(id: id, error: error)
            } else if let i = self.index(id), self.items[i].state == .sending {
                self.items[i].state = .waiting
            }
            self.busy = false
            self.pump()
        }
    }

    // MARK: Replies from the PC

    func saved(id: String, path: String, name: String) {
        guard let i = index(id) else { return }
        items[i].state = .done
        items[i].sent = items[i].size
        items[i].savedPath = path
        items[i].name = name
        removeLocal(i)
    }

    func failed(id: String, error: String) {
        guard let i = index(id) else { return }
        items[i].state = .failed
        items[i].error = error
    }

    func connectionLost() {
        for i in items.indices where items[i].state == .sending || items[i].state == .waiting {
            items[i].state = .queued   // will resend from the start after reconnecting
            items[i].sent = 0
        }
        busy = false
    }

    func retry(_ id: String) {
        guard let i = index(id), items[i].localURL != nil else { return }
        items[i].state = .queued
        items[i].error = nil
        pump()
    }

    func clearFinished() {
        for i in items.indices where items[i].state == .failed { removeLocal(i) }
        items.removeAll { $0.state == .done || $0.state == .failed }
    }

    private func removeLocal(_ i: Int) {
        if let url = items[i].localURL { try? FileManager.default.removeItem(at: url) }
        items[i].localURL = nil
    }

    private func index(_ id: String) -> Int? { items.firstIndex { $0.id == id } }
}

// MARK: - Pickers

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current   // keep originals, no re-encoding
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results)
        }
    }
}

struct FilePicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - Transfer screen

struct TransferView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var transfers: TransferManager
    @AppStorage("usbdeck.heicToJpg") private var heicToJpg = true
    @State private var showPhotos = false
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dërgo te PC")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                if transfers.hasFinished {
                    Button("Pastro listën") { transfers.clearFinished() }
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            if let folder = conn.config?.transfer_folder, !folder.isEmpty {
                Label(folder, systemImage: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                bigButton("Foto & Video", "photo.on.rectangle.angled") { showPhotos = true }
                bigButton("Skedarë", "folder.fill") { showFiles = true }
            }
            .disabled(!conn.connected)
            .opacity(conn.connected ? 1 : 0.4)

            Toggle(isOn: $heicToJpg) {
                Text("Kthe fotot HEIC në JPG (hapen kudo në Windows)")
                    .font(.system(size: 13))
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

            if transfers.items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc.on.clipboard")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.textDim)
                    Text("Zgjidh foto, video ose skedarë – shkojnë direkt te PC-ja me kabllo.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textDim)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(transfers.items.reversed())) { item in
                            TransferRow(item: item,
                                        onReveal: { if let p = item.savedPath { conn.reveal(p) } },
                                        onRetry: { transfers.retry(item.id) })
                        }
                    }
                }
            }
        }
        .padding(16)
        .foregroundColor(.white)
        .sheet(isPresented: $showPhotos) {
            PhotoPicker { results in
                showPhotos = false
                transfers.addFromPhotos(results, convertHEIC: heicToJpg)
            }
        }
        .sheet(isPresented: $showFiles) {
            FilePicker { urls in
                showFiles = false
                transfers.addFiles(urls)
            }
        }
        .onAppear { transfers.pump() }
    }

    private func bigButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 30, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(0.85)))
            .foregroundColor(.white)
        }
    }
}

private struct TransferRow: View {
    let item: TransferManager.Item
    let onReveal: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 30)
                .foregroundColor(item.state == .failed ? Theme.bad : (item.state == .done ? Theme.ok : .white))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(statusText).font(.system(size: 12)).foregroundColor(Theme.textDim)
                }
                if item.state == .sending || item.state == .waiting || item.state == .queued {
                    ProgressView(value: item.progress)
                        .tint(Theme.accent)
                }
            }
            if item.state == .done {
                Button(action: onReveal) {
                    Image(systemName: "folder").font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                }
            } else if item.state == .failed && item.localURL != nil {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .foregroundColor(.white)
    }

    private var icon: String {
        switch item.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default:
            let ext = (item.name as NSString).pathExtension.lowercased()
            if ["mov", "mp4", "m4v", "hevc"].contains(ext) { return "film" }
            if ["jpg", "jpeg", "png", "heic", "heif", "gif"].contains(ext) { return "photo" }
            return "doc"
        }
    }

    private var statusText: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        switch item.state {
        case .preparing: return "Duke përgatitur…"
        case .queued: return "Në pritje · \(size)"
        case .sending: return "\(Int(item.progress * 100))% · \(size)"
        case .waiting: return "Duke ruajtur…"
        case .done: return "U ruajt ✓ · \(size)"
        case .failed: return item.error ?? "Dështoi"
        }
    }
}

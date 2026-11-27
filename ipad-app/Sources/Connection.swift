import Foundation
import Network
import SwiftUI
import UIKit

/// USB link to the PC.
///
/// The iPad listens on 127.0.0.1:2345. The Windows agent reaches that port
/// through Apple's usbmuxd service (installed with iTunes / Apple Devices),
/// so all traffic travels over the Lightning/USB cable – no Wi-Fi needed.
///
/// Framing: 4-byte big-endian length + UTF-8 JSON.
final class Connection: ObservableObject {
    static let port: UInt16 = 2345

    @Published var connected = false
    @Published var config: DeckConfig?
    @Published var activeProfileID: String?
    @Published var activeAppName: String?
    @Published var autoFollow = true
    @Published var toast: String?
    @Published var mixer: MixerState?
    @Published var renders: [String: RenderEvent] = [:]   // in progress, by path
    @Published var renderDone: RenderEvent?

    @Published var brands: [Brand] = []
    @Published var expressions: [ExpressionItem] = []
    @Published var projects: ProjectsMessage?
    @Published var timeSummary: TimeSummary?

    @Published var launchers: [LauncherItem] = []
    @Published var launchersScanning = false
    @Published var paths: [PathItem] = []
    @Published var explorerFolders: [ExplorerFolder]? = nil

    weak var transfers: TransferManager?
    weak var screen: ScreenModel?
    weak var nowPlaying: NowPlaying?
    weak var assistant: AssistantStore?
    weak var premiere: PremiereModel?
    weak var scopes: ScopesModel?
    @Published var beats: BeatsResult?
    @Published var logos: LogosMessage?
    @Published var beatsStatus: BeatsStatus?
    weak var docs: DocStore?
    /// Called once with the PC clipboard text after `requestPCClipboard`.
    private var clipboardHandler: ((String) -> Void)?

    private let queue = DispatchQueue(label: "usbdeck.connection")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var useLoopback = true
    private var toastWork: DispatchWorkItem?

    var profiles: [Profile] { config?.profiles ?? [] }
    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    // MARK: Listener

    func start() {
        queue.async { [weak self] in self?.startListenerIfNeeded() }
    }

    private func startListenerIfNeeded() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Connection.port) else { return }

        let newListener: NWListener
        do {
            if useLoopback {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
                newListener = try NWListener(using: params)
            } else {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                newListener = try NWListener(using: params, on: port)
            }
        } catch {
            useLoopback.toggle()
            scheduleRestart()
            return
        }

        newListener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self = self else { return }
            if case .failed = state {
                newListener?.cancel()
                self.listener = nil
                self.useLoopback.toggle()
                self.scheduleRestart()
            }
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    private func scheduleRestart() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startListenerIfNeeded()
        }
    }

    // MARK: Connection

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        buffer.removeAll()

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.connected = true
                    UIApplication.shared.isIdleTimerDisabled = true   // never sleep while connected
                    self.transfers?.pump()
                }
                var hello: [String: Any] = ["type": "hello", "client": "ipad", "version": 2]
                if let exp = AppExpiry.date { hello["expires"] = exp.timeIntervalSince1970 }
                self.send(hello)
            case .failed, .cancelled:
                if self.connection === conn {
                    self.connection = nil
                    self.docs?.abortAll()
                    DispatchQueue.main.async {
                        self.connected = false
                        self.renders.removeAll()
                        self.transfers?.connectionLost()
                    }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, self.connection === conn {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainBuffer() {
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            if length < 0 || length > 8_000_000 {   // corrupt stream – reset
                buffer.removeAll()
                connection?.cancel()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            if body.first == 0 {
                handleBinary(body)
            } else {
                handle(body)
            }
        }
    }

    /// Binary frames: [0x00][kind][payload]. Kind 1 = JPEG screen frame.
    private func handleBinary(_ body: Data) {
        guard body.count > 2 else { return }
        let kind = body[body.startIndex + 1]
        let payload = body.dropFirst(2)
        if kind >= 2 && kind <= 4 {
            guard let image = UIImage(data: Data(payload)) else {
                if kind == 4 { send(["type": "scopes_ack"]) }
                return
            }
            let decoded = image.preparingForDisplay() ?? image
            DispatchQueue.main.async {
                self.scopes?.set(kind: Int(kind), image: decoded)
                if kind == 4 { self.send(["type": "scopes_ack"]) }
            }
            return
        }
        if kind == 1 {
            guard let image = UIImage(data: Data(payload)) else {
                send(["type": "screen_ack"])
                return
            }
            let decoded = image.preparingForDisplay() ?? image
            DispatchQueue.main.async {
                self.screen?.show(decoded)
                self.send(["type": "screen_ack"])
            }
        }
    }

    private func handle(_ body: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: body) else { return }
        switch envelope.type {
        case "config":
            guard let msg = try? decoder.decode(ConfigMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                self.config = msg.config
                if !msg.config.profiles.contains(where: { $0.id == self.activeProfileID }) {
                    self.activeProfileID = msg.config.profiles.first?.id
                }
            }
        case "active":
            guard let msg = try? decoder.decode(ActiveMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                self.activeAppName = msg.app
                if self.autoFollow, let id = msg.profile, self.profiles.contains(where: { $0.id == id }) {
                    self.activeProfileID = id
                }
            }
        case "toast":
            guard let msg = try? decoder.decode(ToastMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.showToast(msg.text) }
        case "ppro_state":
            guard let msg = try? decoder.decode(PproStateMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.premiere?.apply(msg) }
        case "ppro_pos":
            guard let msg = try? decoder.decode(PproPosMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.premiere?.seconds = msg.seconds }
        case "ppro_status":
            guard let msg = try? decoder.decode(PproStatusMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.premiere?.applyStatus(msg) }
        case "scopes_hist":
            guard let msg = try? decoder.decode(ScopesHistMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.scopes?.hist = msg }
        case "scopes_sources":
            guard let msg = try? decoder.decode(ScreenSourcesMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                self.scopes?.sources = msg.items
                if let c = msg.current { self.scopes?.current = c }
            }
        case "logos":
            guard let msg = try? decoder.decode(LogosMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.logos = msg }
        case "beats_result":
            guard let msg = try? decoder.decode(BeatsResult.self, from: body) else { return }
            DispatchQueue.main.async { self.beats = msg }
        case "beats_status":
            guard let msg = try? decoder.decode(BeatsStatus.self, from: body) else { return }
            DispatchQueue.main.async { self.beatsStatus = msg }
        case "ai_status":
            guard let msg = try? decoder.decode(AIStatus.self, from: body) else { return }
            DispatchQueue.main.async { self.assistant?.status = msg }
        case "ai_delta":
            guard let msg = try? decoder.decode(AIDeltaMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.assistant?.append(id: msg.id, text: msg.text) }
        case "ai_done":
            guard let msg = try? decoder.decode(AIDoneMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.assistant?.finish(id: msg.id, error: nil) }
        case "ai_error":
            guard let msg = try? decoder.decode(AIErrorMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.assistant?.finish(id: msg.id, error: msg.error) }
        case "media":
            guard let msg = try? decoder.decode(MediaMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.nowPlaying?.apply(msg) }
        case "media_pos":
            guard let msg = try? decoder.decode(MediaPosMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.nowPlaying?.applyPosition(msg) }
        case "screen_meta":
            guard let msg = try? decoder.decode(ScreenMetaMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.screen?.setCursor(msg.cx, msg.cy) }
        case "screen_cursor":
            guard let msg = try? decoder.decode(ScreenCursorMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.screen?.setCursor(msg.cx, msg.cy) }
        case "screen_sources":
            guard let msg = try? decoder.decode(ScreenSourcesMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                self.screen?.sources = msg.items
                if let c = msg.current { self.screen?.current = c }
            }
        case "paths":
            guard let msg = try? decoder.decode(PathsMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.paths = msg.items }
        case "paths_explorer":
            guard let msg = try? decoder.decode(ExplorerFoldersMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.explorerFolders = msg.items }
        case "launchers":
            guard let msg = try? decoder.decode(LaunchersMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                self.launchers = msg.items
                self.launchersScanning = msg.scanning ?? false
            }
        case "brands":
            guard let msg = try? decoder.decode(BrandsMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.brands = msg.brands }
        case "expressions":
            guard let msg = try? decoder.decode(ExpressionsMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.expressions = msg.items }
        case "projects":
            guard let msg = try? decoder.decode(ProjectsMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.projects = msg }
        case "backup":
            guard let msg = try? decoder.decode(BackupMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.showToast("💾 Backup: \(msg.name)") }
        case "time":
            guard let msg = try? decoder.decode(TimeSummary.self, from: body) else { return }
            DispatchQueue.main.async { self.timeSummary = msg }
        case "doc_begin":
            guard let msg = try? decoder.decode(DocBeginMessage.self, from: body) else { return }
            docs?.begin(id: msg.id, name: msg.name, size: msg.size)
        case "doc_chunk":
            guard let msg = try? decoder.decode(DocChunkMessage.self, from: body) else { return }
            docs?.chunk(id: msg.id, base64: msg.data)
        case "doc_end":
            guard let msg = try? decoder.decode(DocEndMessage.self, from: body) else { return }
            if let name = docs?.end(id: msg.id) {
                DispatchQueue.main.async { self.showToast("📄 U mor: \(name)") }
            }
        case "file_saved":
            guard let msg = try? decoder.decode(FileSavedMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.transfers?.saved(id: msg.id, path: msg.path, name: msg.name) }
        case "file_error":
            guard let msg = try? decoder.decode(FileErrorMessage.self, from: body) else { return }
            DispatchQueue.main.async { self.transfers?.failed(id: msg.id, error: msg.error) }
        case "clipboard":
            guard let msg = try? decoder.decode(ClipboardMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                let handler = self.clipboardHandler
                self.clipboardHandler = nil
                handler?(msg.text)
            }
        case "mixer":
            guard let msg = try? decoder.decode(MixerMessage.self, from: body) else { return }
            DispatchQueue.main.async {
                if self.mixer != msg.mixer { self.mixer = msg.mixer }
            }
        case "render":
            guard let ev = try? decoder.decode(RenderEvent.self, from: body) else { return }
            DispatchQueue.main.async {
                switch ev.state {
                case "started", "progress":
                    self.renders[ev.path] = ev
                case "done", "failed":
                    self.renders.removeValue(forKey: ev.path)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.renderDone = ev }
                default:
                    self.renders.removeValue(forKey: ev.path)
                }
            }
        default:
            break   // "ping" and unknown messages are ignored
        }
    }

    // MARK: Sending

    func buttonEvent(_ button: DeckButton, profile: Profile, down: Bool) {
        send(["type": "button", "event": down ? "down" : "up", "profile": profile.id, "button": button.id])
    }

    func jog(profile: Profile, mode: String, steps: Int) {
        send(["type": "jog", "profile": profile.id, "mode": mode, "steps": steps])
    }

    func transport(profile: Profile, name: String) {
        send(["type": "transport", "profile": profile.id, "name": name])
    }

    func applyEase(_ curve: [Double]) {
        send(["type": "ease", "curve": curve])
    }

    func setVolume(target: String, key: String, value: Double) {
        send(["type": "volume", "target": target, "key": key, "value": value])
    }

    func toggleMute(target: String, key: String) {
        send(["type": "mute", "target": target, "key": key])
    }

    func setOutput(_ id: String) {
        send(["type": "output", "id": id])
    }

    func saveBrands(_ brands: [Brand]) {
        guard let data = try? JSONEncoder().encode(brands),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        self.brands = brands
        send(["type": "brands_save", "brands": obj])
    }

    func colorAction(_ hex: String, action: String) {
        send(["type": "color", "hex": hex, "action": action])
    }

    func applyExpression(_ id: String) {
        send(["type": "expr_apply", "id": id])
    }

    func screenshot() { send(["type": "screenshot"]) }

    func beatsPick() { send(["type": "beats_pick"]) }
    func beatsExport(target: String, mode: String, offset: Double, fps: Int) {
        send(["type": "beats_export", "target": target, "mode": mode, "offset": offset, "fps": fps])
    }

    func copyToPC(_ text: String) { send(["type": "pc_copy", "text": text]) }

    func requestLogos(brand: String, open: Bool = false) {
        send(["type": open ? "logos_open" : "logos_request", "brand": brand])
    }

    func placeLogo(_ path: String, timeline: Bool) {
        send(["type": "logo_place", "path": path, "timeline": timeline])
    }

    func mediaCommand(_ action: String, value: Any? = nil) {
        var msg: [String: Any] = ["type": "media_cmd", "action": action]
        if let value = value { msg["value"] = value }
        send(msg)
    }

    func screenStart(_ source: String) { send(["type": "screen_start", "source": source]) }
    func screenStop() { send(["type": "screen_stop"]) }
    func screenTouch(x: Double, y: Double, action: String) {
        send(["type": "screen_touch", "x": x, "y": y, "action": action])
    }

    func requestLaunchers() { send(["type": "launchers_request"]) }

    func requestPaths() { send(["type": "paths_request"]) }
    func insertPath(_ id: String, enter: Bool) { send(["type": "path_insert", "id": id, "enter": enter]) }
    func revealPath(_ id: String) { send(["type": "path_reveal", "id": id]) }
    func copyPath(_ id: String) { send(["type": "path_copy", "id": id]) }
    func deletePath(_ id: String) { send(["type": "path_delete", "id": id]) }
    func addPath(_ path: String, name: String = "") { send(["type": "path_add", "path": path, "name": name]) }
    func requestExplorerFolders() {
        explorerFolders = nil
        send(["type": "paths_explorer"])
    }
    func launch(_ index: Int) { send(["type": "launch", "index": index]) }

    func requestProjects() { send(["type": "projects_request"]) }

    func openProject(_ path: String) { send(["type": "project_open", "path": path]) }

    func revealProject(_ path: String, backups: Bool) {
        send(["type": "project_reveal", "path": path, "backups": backups])
    }

    func newProject(client: String, name: String) {
        send(["type": "project_new", "client": client, "name": name])
    }

    func requestTime(_ range: String) { send(["type": "time_request", "range": range]) }

    func goTo(seconds: Double, frames: Int) {
        send(["type": "goto", "seconds": seconds, "frames": frames])
    }

    func requestPCClipboard(_ handler: @escaping (String) -> Void) {
        clipboardHandler = handler
        send(["type": "clipboard_request"])
    }

    func reveal(_ path: String) {
        send(["type": "reveal", "path": path])
    }

    func selectProfileManually(_ id: String) {
        activeProfileID = id
        autoFollow = false
    }

    /// Sends one framed JSON message. `completion(true)` once the bytes were handed to the USB link.
    func send(_ object: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            completion?(false)
            return
        }
        var length = UInt32(body.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(body)
        queue.async { [weak self] in
            guard let conn = self?.connection else {
                completion?(false)
                return
            }
            conn.send(content: packet, completion: .contentProcessed { error in
                completion?(error == nil)
            })
        }
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}

import Foundation

/// Configuration pushed by the Windows agent over USB.
struct DeckConfig: Decodable {
    var grid: GridSize?
    var profiles: [Profile]
    var transfer_folder: String?
}

struct GridSize: Decodable, Hashable {
    var rows: Int
    var cols: Int
}

struct Profile: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let symbol: String?
    let grid: GridSize?
    let pages: [Page]
    let jog: JogInfo?
    let ease: Bool?
}

struct Page: Decodable, Hashable {
    let name: String
    let buttons: [DeckButton?]
}

struct DeckButton: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let symbol: String?
    let color: String?
    let mode: String?   // "tap" | "hold" | "repeat"
}

struct JogInfo: Decodable, Hashable {
    let modes: [JogMode]
    let transport: [String]   // subset of ["reverse", "stop", "forward"]
}

struct JogMode: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
}

// MARK: - Wire messages

struct Envelope: Decodable { let type: String }
struct ConfigMessage: Decodable { let config: DeckConfig }
struct ActiveMessage: Decodable { let profile: String?; let app: String? }
struct ToastMessage: Decodable { let text: String }

// MARK: - Audio mixer

struct MixerState: Decodable, Equatable {
    var available: Bool
    var master: AudioLevel?
    var mic: MicState?
    var outputs: [OutputDevice]?
    var apps: [AppAudio]?
}

struct AudioLevel: Decodable, Equatable {
    var volume: Double
    var muted: Bool
}

struct MicState: Decodable, Equatable {
    var muted: Bool
}

struct OutputDevice: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "default"
    }
}

struct AppAudio: Decodable, Equatable, Identifiable {
    let key: String
    let name: String
    let symbol: String?
    let volume: Double
    let muted: Bool
    let active: Bool
    var id: String { key }
}

struct MixerMessage: Decodable { let mixer: MixerState }

// MARK: - Render notifications

struct RenderEvent: Decodable, Equatable, Identifiable {
    var id = UUID()
    let state: String          // "started" | "progress" | "done" | "failed" | "cancelled"
    let path: String
    let name: String
    let folder: String?
    let size: String?
    let duration: String?
    let finished: String?
    // progress ("progress" events) and failures ("failed")
    let percent: Double?
    let eta: String?
    let written: String?
    let elapsed: String?
    let speed: String?
    let reason: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case state, path, name, folder, size, duration, finished, percent, eta, written, elapsed, speed, reason, source
    }
}

// MARK: - File transfer replies

struct FileSavedMessage: Decodable { let id: String; let path: String; let name: String }
struct FileErrorMessage: Decodable { let id: String; let error: String }
struct ClipboardMessage: Decodable { let text: String }

// MARK: - Brands

struct BrandColor: Codable, Hashable {
    var hex: String
    var name: String
}

struct Brand: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var note: String
    var colors: [BrandColor]
}

struct BrandsMessage: Decodable { let brands: [Brand] }

// MARK: - Expressions

struct ExpressionItem: Decodable, Identifiable, Hashable {
    let id: String
    let category: String
    let name: String
    let description: String
    let code: String
    let needs_keys: Bool?
}

struct ExpressionsMessage: Decodable { let items: [ExpressionItem] }

// MARK: - Projects

struct ProjectItem: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let app: String
    let ext: String
    let folder: String
    let modified: String
    let backup: String?
    var id: String { path }
}

struct ProjectsMessage: Decodable {
    let recent: [ProjectItem]
    let root: String?
    let template: [String]?
    let backup: Bool?
}

struct BackupMessage: Decodable { let name: String; let time: String }

// MARK: - Time tracking

struct TimeApp: Decodable, Hashable { let app: String; let seconds: Int }

struct TimeEntry: Decodable, Identifiable {
    let project: String
    let seconds: Int
    let apps: [TimeApp]
    var id: String { project }
}

struct TimeCurrent: Decodable, Equatable { let project: String; let app: String }

struct TimeSummary: Decodable {
    let range: String
    let items: [TimeEntry]
    let total: Int
    let current: TimeCurrent?
}

// MARK: - Documents PC -> iPad

struct DocBeginMessage: Decodable { let id: String; let name: String; let size: Int64 }
struct DocChunkMessage: Decodable { let id: String; let data: String }
struct DocEndMessage: Decodable { let id: String }

// MARK: - Screen mirroring

struct ScreenSource: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String?
}

struct ScreenSourcesMessage: Decodable { let items: [ScreenSource]; let current: String? }
struct ScreenMetaMessage: Decodable { let w: Int; let h: Int; let cx: Double?; let cy: Double? }
struct ScreenCursorMessage: Decodable { let cx: Double; let cy: Double }

// MARK: - Launcher

struct LauncherItem: Decodable, Identifiable, Hashable {
    let index: Int
    let name: String
    let icon: String?
    let folder: Bool?
    let running: Bool?
    var id: Int { index }
}

struct LaunchersMessage: Decodable { let items: [LauncherItem]; let scanning: Bool? }

// MARK: - Folder paths ("Rrugët")

struct PathItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let exists: Bool?
}

struct PathsMessage: Decodable { let items: [PathItem] }

struct ExplorerFolder: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    var id: String { path }
}

struct ExplorerFoldersMessage: Decodable { let items: [ExplorerFolder] }

// MARK: - Now playing

struct MediaSourceItem: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct MediaMessage: Decodable {
    let available: Bool?
    let active: Bool?
    let source: String?
    let sources: [MediaSourceItem]?
    let app: String?
    let exe: String?
    let title: String?
    let artist: String?
    let album: String?
    let playing: Bool?
    let position: Double?
    let duration: Double?
    let can_seek: Bool?
    let cover: String?
    let cover_id: Int?
}

struct MediaPosMessage: Decodable { let position: Double; let duration: Double; let playing: Bool }

// MARK: - Beat markers

struct BeatPoint: Decodable, Hashable { let t: Double; let s: Double; let bar: Bool }

struct BeatsResult: Decodable {
    let path: String
    let name: String
    let bpm: Double
    let duration: Double
    let beats: [BeatPoint]
    let wave: [Double]
}

struct BeatsStatus: Decodable { let state: String; let text: String }

// MARK: - AI assistant

struct AIModelInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let note: String
}

struct AIPulling: Decodable, Equatable { let model: String; let percent: Int; let status: String }

struct AIStatus: Decodable {
    let model: String
    let models: [AIModelInfo]
    let installed_models: [String]
    let running: Bool
    let installed: Bool
    let pulling: AIPulling?
    let busy: Bool?
    let ready: Bool
}

struct AIDeltaMessage: Decodable { let id: String; let text: String }
struct AIDoneMessage: Decodable { let id: String }
struct AIErrorMessage: Decodable { let id: String; let error: String }

// MARK: - Premiere deep link

struct PproSequence: Decodable, Identifiable, Hashable { let id: String; let name: String }

struct PproSeqInfo: Decodable, Equatable {
    let id: String
    let name: String
    let fps: Double?
    let zero: Double?
    let end: Double?
}

struct PproMarker: Decodable, Identifiable, Hashable {
    let guid: String
    let name: String?
    let comment: String?
    let t: Double
    let color: Int?
    var id: String { guid }
}

struct PproStateMessage: Decodable {
    let connected: Bool
    let project: String?
    let sequences: [PproSequence]?
    let sequence: PproSeqInfo?
    let markers: [PproMarker]?
}

struct PproPosMessage: Decodable { let seconds: Double }

struct PproPreset: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let user: Bool?
    var id: String { path }
}

struct PproStatusMessage: Decodable { let connected: Bool; let installed: Bool; let presets: [PproPreset] }

// MARK: - Scopes

struct ScopesHistMessage: Decodable { let r: [Double]; let g: [Double]; let b: [Double]; let y: [Double] }

// MARK: - Brand logos

struct LogoItem: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let ext: String
    let thumb: String?
    var id: String { path }
}

struct LogosMessage: Decodable { let brand: String; let folder: String; let items: [LogoItem] }

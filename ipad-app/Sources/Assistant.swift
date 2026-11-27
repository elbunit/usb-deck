import SwiftUI
import UIKit

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    let role: String          // "user" | "assistant"
    var content: String
    var streaming = false
    var error: String?
}

/// Local AI assistant (Ollama on the PC).
final class AssistantStore: ObservableObject {
    @Published var status: AIStatus?
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    private let key = "usbdeck.ai.chat"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = saved.map { var m = $0; m.streaming = false; return m }
        }
    }

    var isStreaming: Bool { messages.contains { $0.streaming } }

    func append(id: String, text: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].content += text
    }

    func finish(id: String, error: String?) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].streaming = false
        messages[i].error = error
    }

    private func save() {
        if let data = try? JSONEncoder().encode(messages.suffix(60)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct AssistantView: View {
    @EnvironmentObject var conn: Connection
    @EnvironmentObject var store: AssistantStore
    @State private var input = ""

    private let templates: [(String, String)] = [
        ("Përshkrim YouTube", "Shkruaj një përshkrim për YouTube (me fjalë kyçe dhe kapituj) për videon: "),
        ("Caption Instagram", "Shkruaj 3 caption për Instagram me emoji dhe 15 hashtag për: "),
        ("Tituj", "Më jep 10 tituj tërheqës për videon: "),
        ("Skript reklame 30s", "Shkruaj një skript reklame 30 sekondash (skenat + tekst për voice-over) për: "),
        ("Ide për video", "Më jep 10 ide kreative për video për: "),
        ("Expression AE", "Shkruaj një expression për After Effects që: "),
        ("Email klientit", "Shkruaj një email profesional dhe miqësor për klientin ku: "),
        ("Përkthe në anglisht", "Përkthe në anglisht, natyrshëm: "),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.stroke)
            if let st = store.status {
                if !st.installed {
                    setupCard(icon: "arrow.down.circle", title: "Instalo Ollama (falas)",
                              text: "Ollama e ekzekuton AI-në në PC-në tënde – pa abonim dhe pa e nxjerrë tekstin nga PC-ja. Prek butonin: hapet faqja në PC, shkarko dhe instaloje (2 min).",
                              button: "Hap faqen e shkarkimit në PC") { conn.send(["type": "ai_start"]) }
                } else if !st.running {
                    setupCard(icon: "power", title: "Nis Ollama",
                              text: "Ollama është instaluar, por nuk po punon tani.",
                              button: "Nise në PC") { conn.send(["type": "ai_start"]) }
                } else if !st.ready {
                    modelPicker(st)
                } else {
                    chat
                }
            } else {
                Spacer()
                ProgressView("Duke kontrolluar asistentin…").tint(.white)
                Spacer()
            }
        }
        .foregroundColor(.white)
        .onAppear { conn.send(["type": "ai_status_request"]) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: Symbols.valid("brain.head.profile") ?? "sparkles")
                .font(.system(size: 20))
                .foregroundColor(Theme.accent)
            Text("Asistenti AI").font(.system(size: 22, weight: .bold))
            if let st = store.status, st.ready {
                Menu {
                    ForEach(st.models) { m in
                        Button {
                            conn.send(["type": "ai_set_model", "model": m.id])
                        } label: {
                            Label("\(m.name) · \(m.size)", systemImage: st.installed_models.contains(m.id) ? "checkmark.circle" : "arrow.down.circle")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(st.models.first { $0.id == st.model }?.name ?? st.model)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.raised))
                }
            }
            Spacer()
            Text("lokal · privat · falas").font(.system(size: 11)).foregroundColor(Theme.textDim)
            Button {
                store.messages.removeAll()
            } label: {
                Label("Bisedë e re", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.raised))
            }
            .disabled(store.isStreaming)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Setup

    private func setupCard(icon: String, title: String, text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon).font(.system(size: 50, weight: .light)).foregroundColor(Theme.accent)
            Text(title).font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 14)).foregroundColor(Theme.textDim).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: action) {
                Text(button).font(.system(size: 15, weight: .bold))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.accent))
            }
            Button("Kontrollo prapë") { conn.send(["type": "ai_status_request"]) }
                .font(.system(size: 13))
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func modelPicker(_ st: AIStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Zgjidh modelin AI (shkarkohet një herë)").font(.system(size: 18, weight: .bold))
                ForEach(st.models) { m in
                    let have = st.installed_models.contains(m.id)
                    let pulling = st.pulling?.model == m.id ? st.pulling : nil
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.name).font(.system(size: 16, weight: .bold))
                            Text("\(m.size) · \(m.note)").font(.system(size: 12)).foregroundColor(Theme.textDim)
                            if let p = pulling {
                                ProgressView(value: Double(p.percent) / 100).tint(Theme.accent)
                                Text("\(p.percent)% · \(p.status)").font(.system(size: 11)).foregroundColor(Theme.textDim)
                            }
                        }
                        Spacer()
                        if have {
                            Button("Përdor") { conn.send(["type": "ai_set_model", "model": m.id]) }
                                .font(.system(size: 14, weight: .bold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Capsule().fill(Theme.ok))
                        } else if pulling == nil {
                            Button("Shkarko") {
                                conn.send(["type": "ai_set_model", "model": m.id])
                                conn.send(["type": "ai_pull", "model": m.id])
                            }
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(Theme.accent))
                            .disabled(st.pulling != nil)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(m.id == st.model ? Theme.raised : Theme.panel))
                }
            }
            .padding(16)
        }
    }

    // MARK: Chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.messages.isEmpty {
                            Text("Pyet çfarëdo: përshkrime, caption, tituj, skripte, ide, expressions… Mund edhe të diktosh me 🎙 te tastiera.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textDim)
                                .padding(.top, 20)
                        }
                        ForEach(store.messages) { m in
                            bubble(m).id(m.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: store.messages.last?.content) { _ in
                    if let last = store.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(templates, id: \.0) { t in
                        Button { input = t.1 } label: {
                            Text(t.0).font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(Theme.raised))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Shkruaj ose dikto…").foregroundColor(Theme.textDim).padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    TextEditor(text: $input)
                        .font(.system(size: 15))
                        .padding(6)
                        .frame(height: 76)
                        .opacity(input.isEmpty ? 0.9 : 1)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
                if store.isStreaming {
                    Button { conn.send(["type": "ai_stop"]) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 18, weight: .bold))
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Theme.bad))
                    }
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 20, weight: .bold))
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Theme.accent))
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conn.connected)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let mine = m.role == "user"
        return HStack {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 8) {
                if m.content.isEmpty && m.streaming {
                    ProgressView().tint(.white)
                } else {
                    Text(m.content)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                }
                if let err = m.error {
                    Text(err).font(.system(size: 12)).foregroundColor(Theme.bad)
                }
                if !mine && !m.streaming && !m.content.isEmpty {
                    HStack(spacing: 8) {
                        smallButton("Kopjo në PC", "desktopcomputer") { conn.copyToPC(m.content) }
                        smallButton("Kopjo", "doc.on.doc") {
                            UIPasteboard.general.string = m.content
                            conn.showToast("U kopjua në iPad")
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(mine ? Theme.accent.opacity(0.85) : Theme.panel))
            if !mine { Spacer(minLength: 80) }
        }
    }

    private func smallButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Theme.raised))
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        store.messages.append(ChatMessage(role: "user", content: text))
        let reply = ChatMessage(role: "assistant", content: "", streaming: true)
        store.messages.append(reply)
        let history: [[String: Any]] = store.messages
            .filter { !$0.streaming && $0.error == nil }
            .map { ["role": $0.role, "content": $0.content] }
        conn.send(["type": "ai_chat", "id": reply.id, "messages": history])
    }
}

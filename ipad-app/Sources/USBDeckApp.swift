import SwiftUI
import UIKit

@main
struct USBDeckApp: App {
    @StateObject private var conn = Connection()
    @StateObject private var transfers = TransferManager()
    @StateObject private var revisions = RevisionStore()
    @StateObject private var docs = DocStore()
    @StateObject private var screen = ScreenModel()
    @StateObject private var nowPlaying = NowPlaying()
    @StateObject private var assistant = AssistantStore()
    @StateObject private var premiere = PremiereModel()
    @StateObject private var scopes = ScopesModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conn)
                .environmentObject(transfers)
                .environmentObject(revisions)
                .environmentObject(docs)
                .environmentObject(screen)
                .environmentObject(nowPlaying)
                .environmentObject(assistant)
                .environmentObject(premiere)
                .environmentObject(scopes)
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    AppExpiry.scheduleReminders()
                    transfers.conn = conn
                    conn.transfers = transfers
                    conn.docs = docs
                    conn.screen = screen
                    conn.nowPlaying = nowPlaying
                    conn.assistant = assistant
                    conn.premiere = premiere
                    conn.scopes = scopes
                    conn.start()
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                conn.start()
            }
        }
    }
}

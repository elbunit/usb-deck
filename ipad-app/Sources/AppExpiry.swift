import SwiftUI
import UserNotifications

/// Free Apple ID sideloads expire after 7 days. The expiry date is inside the
/// provisioning profile that Sideloadly embeds in the app (embedded.mobileprovision).
enum AppExpiry {
    static let date: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static var remaining: TimeInterval? { date.map { $0.timeIntervalSinceNow } }

    static func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "sq_AL")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "'sot në' HH:mm" }
        else if cal.isDateInTomorrow(d) { f.dateFormat = "'nesër në' HH:mm" }
        else { f.dateFormat = "d MMM 'në' HH:mm" }
        return f.string(from: d)
    }

    /// Local notifications 1 day and 2 hours before expiry (work even when the app is closed).
    static func scheduleReminders() {
        guard let date = date, date.timeIntervalSinceNow > 0 else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            center.removePendingNotificationRequests(withIdentifiers: ["expiry-24h", "expiry-2h"])
            let items: [(String, TimeInterval, String)] = [
                ("expiry-24h", 24 * 3600, "USB Deck skadon nesër. Lidhe iPad-in me PC-në dhe rinstaloje me Sideloadly (2 minuta)."),
                ("expiry-2h", 2 * 3600, "USB Deck skadon pas 2 orësh! Rinstaloje tani me Sideloadly që të mos të ndalet gjatë punës."),
            ]
            for (id, before, text) in items {
                let fire = date.addingTimeInterval(-before)
                guard fire.timeIntervalSinceNow > 5 else { continue }
                let content = UNMutableNotificationContent()
                content.title = "⏳ USB Deck"
                content.body = text
                content.sound = .default
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}

/// Banner shown over the deck when less than ~1.5 days are left.
struct ExpiryBanner: View {
    @State private var hidden = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !hidden, let date = AppExpiry.date, date.timeIntervalSince(now) < 36 * 3600 {
                let left = date.timeIntervalSince(now)
                let urgent = left < 6 * 3600
                HStack(spacing: 12) {
                    Image(systemName: urgent ? "exclamationmark.triangle.fill" : "hourglass")
                        .font(.system(size: 18, weight: .bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(left <= 0 ? "Aplikacioni ka skaduar" : "Aplikacioni skadon \(AppExpiry.formatted(date))")
                            .font(.system(size: 15, weight: .bold))
                        Text("Lidhe iPad-in, hap Sideloadly dhe instalo përsëri USBDeck.ipa – nuk humbet asgjë.")
                            .font(.system(size: 12))
                            .opacity(0.85)
                    }
                    Spacer(minLength: 8)
                    Button { hidden = true } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).padding(8)
                    }
                }
                .foregroundColor(urgent ? .white : .black)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(urgent ? Theme.bad : Color(red: 0.91, green: 0.64, blue: 0.09)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .padding(.horizontal, 220).padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(tick) { now = $0 }
    }
}

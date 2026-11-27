import Combine
import SwiftUI
import UIKit

/// "Programet": open (or bring to front) PC programs with one tap.
struct LauncherView: View {
    @EnvironmentObject var conn: Connection
    @State private var pressed: Int?
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Programet").font(.system(size: 22, weight: .bold))
                Spacer()
                Button { conn.requestLaunchers() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 18, weight: .semibold))
                }
            }

            if conn.launchers.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: conn.launchersScanning ? "hourglass" : "square.grid.2x2")
                        .font(.system(size: 44))
                        .foregroundColor(Theme.textDim)
                    Text(conn.launchersScanning ? "Duke kërkuar programet në PC…" : "Asnjë program ende")
                        .font(.system(size: 18, weight: .bold))
                    Text("Zgjidhi te editori në PC → ⚙ Cilësimet → Programet në iPad.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textDim)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 12)], spacing: 12) {
                        ForEach(conn.launchers) { item in
                            tile(item)
                        }
                    }
                }
                Text("Pika jeshile = programi është i hapur (prekja e sjell përpara).")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textDim)
            }
        }
        .padding(16)
        .foregroundColor(.white)
        .onAppear { conn.requestLaunchers() }
        .onReceive(refresh) { _ in conn.requestLaunchers() }
    }

    private func tile(_ item: LauncherItem) -> some View {
        Button {
            pressed = item.index
            conn.launch(item.index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pressed = nil }
        } label: {
            VStack(spacing: 10) {
                Group {
                    if let b64 = item.icon, !b64.isEmpty, let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: item.folder == true ? "folder.fill" : "app.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundColor(item.folder == true ? Color(red: 0.35, green: 0.65, blue: 1) : Theme.textDim)
                            .padding(4)
                    }
                }
                .frame(width: 52, height: 52)

                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
                    .frame(height: 34)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(pressed == item.index ? Theme.accent : Theme.stroke, lineWidth: pressed == item.index ? 2 : 1))
            .overlay(Circle().fill(item.running == true ? Theme.ok : Color.clear).frame(width: 10, height: 10).padding(10),
                     alignment: .topTrailing)
            .scaleEffect(pressed == item.index ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .foregroundColor(.white)
        }
    }
}

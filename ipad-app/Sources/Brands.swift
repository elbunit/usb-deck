import SwiftUI
import UIKit

/// Brand colour palettes, stored on the PC (brands.json) and edited here.
struct BrandsView: View {
    @EnvironmentObject var conn: Connection
    @State private var selectedID: String?
    @State private var selectedColor: Int?
    @State private var pickerColor = Color(red: 0.32, green: 0.55, blue: 1.0)
    @State private var newColorName = ""
    @State private var hexPaste = ""
    @State private var nameDraft = ""
    @State private var noteDraft = ""
    @AppStorage("usbdeck.logoTimeline") private var logoToTimeline = false

    private var index: Int? {
        let id = selectedID ?? conn.brands.first?.id
        return conn.brands.firstIndex { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            brandList
                .frame(width: 210)
                .background(Theme.panel.opacity(0.6))
            Divider().background(Theme.stroke)
            if let i = index {
                detail(i)
                    .id(conn.brands[i].id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 46))
                        .foregroundColor(Theme.textDim)
                    Text(conn.connected ? "Krijo brendin e parë" : "Lidh iPad-in me PC-në")
                        .font(.system(size: 20, weight: .bold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundColor(.white)
    }

    // MARK: List

    private var brandList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brendet")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 14)
            Button {
                var list = conn.brands
                let brand = Brand(id: UUID().uuidString.prefix(8).lowercased(), name: "Brend i ri", note: "", colors: [])
                list.insert(brand, at: 0)
                conn.saveBrands(list)
                selectedID = brand.id
                selectedColor = nil
            } label: {
                Label("Brend i ri", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
            }
            .disabled(!conn.connected)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(conn.brands) { brand in
                        Button {
                            selectedID = brand.id
                            selectedColor = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(brand.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                HStack(spacing: 3) {
                                    ForEach(Array(brand.colors.prefix(8).enumerated()), id: \.offset) { _, c in
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color(hex: c.hex, fallback: .gray))
                                            .frame(width: 18, height: 18)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(brand.id == (selectedID ?? conn.brands.first?.id) ? Theme.raised : Color.clear))
                            .foregroundColor(.white)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Detail

    private func detail(_ i: Int) -> some View {
        let brand = conn.brands[i]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Emri i brendit", text: $nameDraft, onCommit: { commitTexts(i) })
                        .font(.system(size: 22, weight: .bold))
                    Menu {
                        Button(role: .destructive) {
                            var list = conn.brands
                            list.remove(at: i)
                            conn.saveBrands(list)
                            selectedID = nil
                        } label: { Label("Fshi brendin", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 22))
                    }
                }
                TextField("Shënime: fontet, logo, rregulla…", text: $noteDraft, onCommit: { commitTexts(i) })
                    .font(.system(size: 14))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(Array(brand.colors.enumerated()), id: \.offset) { ci, c in
                        Button {
                            selectedColor = (selectedColor == ci) ? nil : ci
                        } label: {
                            VStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(hex: c.hex, fallback: .gray))
                                    .frame(height: 74)
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(selectedColor == ci ? Color.white : Color.white.opacity(0.12),
                                                      lineWidth: selectedColor == ci ? 3 : 1))
                                VStack(spacing: 1) {
                                    Text(c.hex).font(.system(size: 12, weight: .bold, design: .monospaced))
                                    if !c.name.isEmpty {
                                        Text(c.name).font(.system(size: 10)).foregroundColor(Theme.textDim).lineLimit(1)
                                    }
                                }
                                .padding(.top, 5)
                            }
                            .foregroundColor(.white)
                        }
                    }
                }

                if let ci = selectedColor, brand.colors.indices.contains(ci) {
                    let hex = brand.colors[ci].hex
                    HStack(spacing: 10) {
                        actionButton("Kopjo HEX në PC", "doc.on.doc.fill", Theme.accent) { conn.colorAction(hex, action: "copy") }
                        actionButton("Apliko në AE", "sparkles", Color(red: 0.48, green: 0.31, blue: 0.84)) { conn.colorAction(hex, action: "ae") }
                        actionButton("Fshi", "trash", Theme.bad) {
                            var list = conn.brands
                            if list.indices.contains(i), list[i].colors.indices.contains(ci) {
                                list[i].colors.remove(at: ci)
                                conn.saveBrands(list)
                            }
                            selectedColor = nil
                        }
                    }
                    Text("“Apliko në AE”: shape → Fill, tekst → ngjyra e tekstit, solid → ngjyra, të tjerat → efekti Fill.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textDim)
                }

                Divider().background(Theme.stroke)

                logosSection(brand)

                Divider().background(Theme.stroke)

                Text("Shto ngjyrë").font(.system(size: 15, weight: .bold))
                HStack(spacing: 10) {
                    ColorPicker("", selection: $pickerColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 44)
                    TextField("Emri (opsional)", text: $newColorName)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                    Button {
                        addColors(i, [BrandColor(hex: hexString(pickerColor), name: newColorName)])
                        newColorName = ""
                    } label: {
                        Text("Shto").font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.accent))
                    }
                }
                HStack(spacing: 10) {
                    TextField("Ngjit kode HEX: #0B1F3A, #F2B705 …", text: $hexPaste)
                        .font(.system(size: 13, design: .monospaced))
                        .autocapitalization(.none)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                    Button {
                        addColors(i, parseHexes(hexPaste))
                        hexPaste = ""
                    } label: {
                        Text("Shto të gjitha").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.raised))
                    }
                    .disabled(parseHexes(hexPaste).isEmpty)
                }
            }
            .padding(16)
        }
        .onAppear {
            nameDraft = brand.name
            noteDraft = brand.note
            conn.requestLogos(brand: brand.id)
        }
        .onDisappear { commitTexts(i) }
    }

    // MARK: Logos

    @ViewBuilder
    private func logosSection(_ brand: Brand) -> some View {
        let logos = conn.logos?.brand == brand.id ? (conn.logos?.items ?? []) : []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Logot").font(.system(size: 15, weight: .bold))
                Text("prek → vendoset në projektin e hapur").font(.system(size: 12)).foregroundColor(Theme.textDim)
                Spacer()
                Button { conn.requestLogos(brand: brand.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                }
                Button { conn.requestLogos(brand: brand.id, open: true) } label: {
                    Label("Hap dosjen në PC", systemImage: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.raised))
                }
            }
            Toggle(isOn: $logoToTimeline) {
                Text("Premiere: vendose edhe në timeline te playhead-i (track-u më i lartë)").font(.system(size: 12))
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            if logos.isEmpty {
                Text("Ende pa logo. Prek “Hap dosjen në PC” dhe vendos aty logot e këtij brendi (PNG, SVG, AI, PSD, MOV me alfa…).")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textDim)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                    ForEach(logos) { logo in
                        Button { conn.placeLogo(logo.path, timeline: logoToTimeline) } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Checkerboard().clipShape(RoundedRectangle(cornerRadius: 10))
                                    if let b64 = logo.thumb, !b64.isEmpty, let data = Data(base64Encoded: b64),
                                       let img = UIImage(data: data) {
                                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fit).padding(8)
                                    } else {
                                        VStack(spacing: 4) {
                                            Image(systemName: "doc.richtext").font(.system(size: 26))
                                            Text(logo.ext.uppercased()).font(.system(size: 11, weight: .bold))
                                        }
                                        .foregroundColor(Color.black.opacity(0.6))
                                    }
                                }
                                .frame(height: 84)
                                Text(logo.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundColor(.white)
                        }
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(color))
                .foregroundColor(.white)
        }
    }

    // MARK: Helpers

    private func commitTexts(_ i: Int) {
        var list = conn.brands
        guard list.indices.contains(i) else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        if (name.isEmpty || name == list[i].name) && noteDraft == list[i].note { return }
        if !name.isEmpty { list[i].name = name }
        list[i].note = noteDraft
        conn.saveBrands(list)
    }

    private func addColors(_ i: Int, _ colors: [BrandColor]) {
        guard !colors.isEmpty else { return }
        var list = conn.brands
        guard list.indices.contains(i) else { return }
        list[i].colors.append(contentsOf: colors)
        conn.saveBrands(list)
    }

    private func parseHexes(_ text: String) -> [BrandColor] {
        guard let re = try? NSRegularExpression(pattern: "#?([0-9A-Fa-f]{6})\\b") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return BrandColor(hex: "#" + text[r].uppercased(), name: "")
        }
    }

    private func hexString(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// Light checkerboard so transparent logos are visible.
private struct Checkerboard: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let size: CGFloat = 10
                let cols = Int(geo.size.width / size) + 1
                let rows = Int(geo.size.height / size) + 1
                for r in 0..<rows {
                    for c in 0..<cols where (r + c) % 2 == 0 {
                        p.addRect(CGRect(x: CGFloat(c) * size, y: CGFloat(r) * size, width: size, height: size))
                    }
                }
            }
            .fill(Color(white: 0.82))
            .background(Color(white: 0.95))
        }
    }
}

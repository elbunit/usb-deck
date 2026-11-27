import SwiftUI

/// After Effects expression library: search, pick, apply to the selected property.
struct ExpressionsView: View {
    @EnvironmentObject var conn: Connection
    @State private var query = ""
    @State private var category: String?
    @State private var expanded: String?

    private var categories: [String] {
        var seen: [String] = []
        for e in conn.expressions where !seen.contains(e.category) { seen.append(e.category) }
        return seen
    }

    private var filtered: [ExpressionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return conn.expressions.filter { e in
            (category == nil || e.category == category) &&
            (q.isEmpty || e.name.lowercased().contains(q) || e.description.lowercased().contains(q) || e.code.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Expressions").font(.system(size: 22, weight: .bold))
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.textDim)
                    TextField("Kërko… (wiggle, loop, counter)", text: $query)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Të gjitha", selected: category == nil) { category = nil }
                    ForEach(categories, id: \.self) { c in
                        chip(c, selected: category == c) { category = c }
                    }
                }
            }

            Text("Zgjidh property-n në After Effects (p.sh. Position, Scale, Source Text) dhe prek “Apliko”. Ctrl+Z e kthen.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textDim)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(filtered) { e in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(e.name).font(.system(size: 15, weight: .bold))
                                        if e.needs_keys == true {
                                            Text("keyframe")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Capsule().fill(Theme.raised))
                                        }
                                    }
                                    Text(e.description).font(.system(size: 12)).foregroundColor(Theme.textDim)
                                }
                                Spacer()
                                Button {
                                    expanded = (expanded == e.id) ? nil : e.id
                                } label: {
                                    Image(systemName: expanded == e.id ? "chevron.up" : "curlybraces")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(width: 38, height: 36)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                                }
                                Button { conn.applyExpression(e.id) } label: {
                                    Text("Apliko").font(.system(size: 14, weight: .bold))
                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(Capsule().fill(Color(red: 0.48, green: 0.31, blue: 0.84)))
                                }
                                .disabled(!conn.connected)
                            }
                            if expanded == e.id {
                                Text(e.code)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    }
                }
            }
        }
        .padding(16)
        .foregroundColor(.white)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Theme.accent : Theme.raised))
                .foregroundColor(.white)
        }
    }
}

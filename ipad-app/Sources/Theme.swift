import SwiftUI
import UIKit

enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let panel = Color(red: 0.085, green: 0.089, blue: 0.10)
    static let raised = Color(red: 0.13, green: 0.135, blue: 0.15)
    static let stroke = Color.white.opacity(0.07)
    static let textDim = Color.white.opacity(0.55)
    static let accent = Color(red: 0.32, green: 0.55, blue: 1.0)
    static let ok = Color(red: 0.2, green: 0.8, blue: 0.45)
    static let bad = Color(red: 0.95, green: 0.33, blue: 0.33)
    static let defaultButton = Color(red: 0.25, green: 0.27, blue: 0.31)
}

extension Color {
    /// "#RRGGBB" → Color, or `fallback` when missing/invalid.
    init(hex: String?, fallback: Color) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            self = fallback
            return
        }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = fallback
            return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255.0,
                     green: Double((v >> 8) & 0xFF) / 255.0,
                     blue: Double(v & 0xFF) / 255.0)
    }
}

/// Only shows SF Symbols that exist on this iPadOS version.
enum Symbols {
    private static var cache: [String: Bool] = [:]

    static func valid(_ name: String?) -> String? {
        guard let name = name, !name.isEmpty else { return nil }
        if let known = cache[name] { return known ? name : nil }
        let ok = UIImage(systemName: name) != nil
        cache[name] = ok
        return ok ? name : nil
    }
}

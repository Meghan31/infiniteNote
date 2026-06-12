import Foundation
import UIKit
import PencilKit
import GRDB

/// A saved pen preset — name, look, and stroke behavior.
///
/// How the parameters take effect (PencilKit reality):
///   • `width`, color, `opacity`, `inkFlow`, `softness` map directly onto the
///     live `PKInkingTool` (softness ≥ 0.7 switches to the textured pencil ink).
///   • `stabilization`, `bezierSmoothing`, `pressureSensitivity`,
///     `startTaper`/`endTaper`, `velocitySensitivity`, `minWidth`/`maxWidth`
///     are applied by `StrokeRefiner` the moment a stroke is completed —
///     PencilKit doesn't expose its in-flight ink engine, so the refinement
///     happens on the finished stroke (the standard approach in note apps).
struct CustomPen: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// "RRGGBB" — rendered alpha comes from `opacity` × `inkFlow`.
    var colorHex: String
    var opacity: Double            // 0.2 ... 1
    var width: Double              // pt, 1 ... 24
    var stabilization: Double      // 0 ... 1 — jitter removal
    var bezierSmoothing: Double    // 0 ... 1 — curve refit
    var pressureSensitivity: Double// 0 ... 0.2 — max width variation (0–20 %)
    var startTaper: Double         // 0 ... 1
    var endTaper: Double           // 0 ... 1
    var inkFlow: Double            // 0.3 ... 1 — modulates ink alpha
    var softness: Double           // 0 ... 1 — ≥ 0.7 uses the pencil texture
    var velocitySensitivity: Double// 0 ... 1 — fast strokes thin slightly
    var minWidth: Double           // pt clamp
    var maxWidth: Double           // pt clamp
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        colorHex: String = "000000",
        opacity: Double = 1,
        width: Double = 3,
        stabilization: Double = 0.5,
        bezierSmoothing: Double = 0.5,
        pressureSensitivity: Double = 0.08,
        startTaper: Double = 0.4,
        endTaper: Double = 0.5,
        inkFlow: Double = 1,
        softness: Double = 0,
        velocitySensitivity: Double = 0.15,
        minWidth: Double = 1.5,
        maxWidth: Double = 6,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.opacity = opacity
        self.width = width
        self.stabilization = stabilization
        self.bezierSmoothing = bezierSmoothing
        self.pressureSensitivity = pressureSensitivity
        self.startTaper = startTaper
        self.endTaper = endTaper
        self.inkFlow = inkFlow
        self.softness = softness
        self.velocitySensitivity = velocitySensitivity
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Default Pen
    //
    // The built-in handwriting pen: monoline character (variation clamped to
    // ~7 %), strong stabilization + Bézier smoothing, tapered stroke ends,
    // no nib-angle / direction effects (the .pen ink has none), consistent
    // ink. It cannot be deleted, renamed, or modified.

    static let defaultPenId = "default-pen"

    static let defaultPen = CustomPen(
        id: defaultPenId,
        name: "Default Pen",
        colorHex: "000000",
        opacity: 1,
        width: 3,
        stabilization: 0.55,
        bezierSmoothing: 0.6,
        pressureSensitivity: 0.07,   // 5–10 % band → 7 %
        startTaper: 0.45,
        endTaper: 0.55,
        inkFlow: 1,
        softness: 0,
        velocitySensitivity: 0.18,
        minWidth: 1.6,
        maxWidth: 4.6,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )

    var isDefault: Bool { id == Self.defaultPenId }

    // MARK: - Live tool mapping

    /// The PencilKit tool for this pen. `color`/`width` come from the toolbar
    /// (a custom pen loads its saved values into the toolbar when selected,
    /// so they stay user-tweakable without rewriting the preset).
    func inkingTool(color: UIColor, width: CGFloat) -> PKInkingTool {
        let alpha = CGFloat(max(0.05, min(1, opacity * (0.45 + 0.55 * inkFlow))))
        let inkColor = color.withAlphaComponent(alpha * color.cgColor.alpha)
        let type: PKInkingTool.InkType = softness >= 0.7 ? .pencil : .pen
        return PKInkingTool(type, color: inkColor, width: width)
    }

    // MARK: - Preview rendering

    /// A wavy sample stroke run through the SAME `StrokeRefiner` as live ink,
    /// so previews show exactly the character the pen writes with.
    func previewImage(size: CGSize = CGSize(width: 132, height: 38), dark: Bool) -> UIImage {
        let count = 36
        var points: [PKStrokePoint] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = 6 + t * (size.width - 12)
            let y = size.height / 2 + sin(t * .pi * 2.1) * (size.height * 0.26)
            // Simulated pressure/speed wobble — the refiner clamps it to the
            // pen's own pressureSensitivity.
            let wobble = 1 + 0.3 * sin(t * .pi * 6.5)
            let w = CGFloat(width) * wobble
            points.append(PKStrokePoint(
                location: CGPoint(x: x, y: y),
                timeOffset: TimeInterval(t) * 0.5,
                size: CGSize(width: w, height: w),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            ))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: .now)
        let ink = PKInk(softness >= 0.7 ? .pencil : .pen,
                        color: UIColor(Color(hex: colorHex))
                            .withAlphaComponent(CGFloat(max(0.05, min(1, opacity * (0.45 + 0.55 * inkFlow))))))
        let refined = StrokeRefiner.refine(PKStroke(ink: ink, path: path), with: self)

        var image = UIImage()
        let render = {
            image = PKDrawing(strokes: [refined])
                .image(from: CGRect(origin: .zero, size: size), scale: 2)
        }
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent(render)
        return image
    }
}

// MARK: - SwiftUI bridge

import SwiftUI

extension CustomPen {
    var color: Color { Color(hex: colorHex) }

    /// Hex (RRGGBB, no alpha) from a SwiftUI color — alpha is carried by
    /// `opacity` instead.
    static func hexString(from color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }
}

// MARK: - GRDB Conformances

extension CustomPen: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "custom_pens"

    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        colorHex = row["color_hex"] ?? "000000"
        opacity = row["opacity"] ?? 1
        width = row["width"] ?? 3
        stabilization = row["stabilization"] ?? 0.5
        bezierSmoothing = row["bezier_smoothing"] ?? 0.5
        pressureSensitivity = row["pressure_sensitivity"] ?? 0.08
        startTaper = row["start_taper"] ?? 0.4
        endTaper = row["end_taper"] ?? 0.5
        inkFlow = row["ink_flow"] ?? 1
        softness = row["softness"] ?? 0
        velocitySensitivity = row["velocity_sensitivity"] ?? 0.15
        minWidth = row["min_width"] ?? 1.5
        maxWidth = row["max_width"] ?? 6
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["color_hex"] = colorHex
        container["opacity"] = opacity
        container["width"] = width
        container["stabilization"] = stabilization
        container["bezier_smoothing"] = bezierSmoothing
        container["pressure_sensitivity"] = pressureSensitivity
        container["start_taper"] = startTaper
        container["end_taper"] = endTaper
        container["ink_flow"] = inkFlow
        container["softness"] = softness
        container["velocity_sensitivity"] = velocitySensitivity
        container["min_width"] = minWidth
        container["max_width"] = maxWidth
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
}

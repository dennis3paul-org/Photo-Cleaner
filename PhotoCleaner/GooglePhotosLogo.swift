import SwiftUI

/// The four-petal Google Photos pinwheel mark, drawn with SwiftUI Paths so it
/// scales to any size and matches the rest of the UI's vector aesthetic.
///
/// Each petal is a leaf / vesica-piscis shape: two quarter-circles meeting at
/// a tip on the outside and at the center on the inside. Rotated 90° around
/// the center to produce the iconic spinning mark.
///
/// This is a hand-drawn approximation in the GP brand colors — used purely
/// as a visual cue on the "Connect Google Photos" affordance. Not a faithful
/// reproduction of the trademarked asset; intentionally distinct.
struct GooglePhotosLogo: View {
    /// GP brand-inspired colors. Deliberately slightly off from the real
    /// trademarked palette.
    private static let petalColors: [Color] = [
        Color(red: 0.98, green: 0.75, blue: 0.10),   // top — yellow
        Color(red: 0.93, green: 0.27, blue: 0.21),   // right — red
        Color(red: 0.26, green: 0.55, blue: 0.96),   // bottom — blue
        Color(red: 0.22, green: 0.67, blue: 0.33)    // left — green
    ]

    var body: some View {
        Canvas { context, size in
            drawPetals(context: context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Draws all four petals into the Canvas context. Split out of `body`
    /// so the Swift type-checker doesn't choke on a single giant closure.
    private func drawPetals(context: GraphicsContext, size: CGSize) {
        let s = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let length = s * 0.46
        let bulge = s * 0.30

        for i in 0..<4 {
            let angle: CGFloat = CGFloat(i) * (.pi / 2) - (.pi / 2) // 0 = top, then CW
            let path = petalPath(center: center, angle: angle, length: length, bulge: bulge)
            context.fill(path, with: .color(Self.petalColors[i]))
        }
    }

    /// Builds one leaf-shaped petal path for the given angle.
    private func petalPath(
        center: CGPoint,
        angle: CGFloat,
        length: CGFloat,
        bulge: CGFloat
    ) -> Path {
        // Tip of the petal (outer end).
        let tip = CGPoint(
            x: center.x + cos(angle) * length,
            y: center.y + sin(angle) * length
        )
        // Two control points to either side, half-way along the axis,
        // pushed perpendicular to create the bulge.
        let midAxisX = cos(angle) * length * 0.5
        let midAxisY = sin(angle) * length * 0.5
        let leftCtl = CGPoint(
            x: center.x + cos(angle - .pi / 2) * bulge + midAxisX,
            y: center.y + sin(angle - .pi / 2) * bulge + midAxisY
        )
        let rightCtl = CGPoint(
            x: center.x + cos(angle + .pi / 2) * bulge + midAxisX,
            y: center.y + sin(angle + .pi / 2) * bulge + midAxisY
        )

        var path = Path()
        path.move(to: center)
        path.addQuadCurve(to: tip, control: leftCtl)
        path.addQuadCurve(to: center, control: rightCtl)
        return path
    }
}

#Preview {
    GooglePhotosLogo()
        .frame(width: 80, height: 80)
        .padding(40)
}

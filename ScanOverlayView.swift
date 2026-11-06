import SwiftUI

struct ScanOverlayView: View {
    let contour: [CGPoint]
    let uncertain: Bool
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard let first = contour.first else { return }
                path.move(to: CGPoint(x: first.x * geometry.size.width, y: first.y * geometry.size.height))
                for point in contour.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * geometry.size.width, y: point.y * geometry.size.height))
                }
                path.closeSubpath()
            }
            .stroke(uncertain ? Color.orange : Color.green,
                    style: StrokeStyle(lineWidth: 2, dash: uncertain ? [7, 4] : []))
        }
        .allowsHitTesting(false)
        .accessibilityLabel(uncertain ? "Contorno da controllare" : "Contorno pagina")
    }
}

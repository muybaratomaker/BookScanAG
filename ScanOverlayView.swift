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

struct ScanSeamOverlay: View {
    let points: [CGPoint]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: first.x * geo.size.width, y: first.y * geo.size.height))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x * geo.size.width, y: point.y * geo.size.height))
                }
            }.stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        }.allowsHitTesting(false)
    }
}

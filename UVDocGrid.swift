import Foundation

/// Backward map in normalized top-left coordinates, using align_corners=True.
/// Portable geometry; no learned confidence is inferred from these structural checks.
struct UVDocGrid {
    struct Point {
        let x: Double
        let y: Double
    }
    let width: Int
    let height: Int
    let points: [Point]

    var isSafe: Bool {
        guard width > 1, height > 1, points.count == width * height,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (-0.06...1.06).contains($0.x) && (-0.06...1.06).contains($0.y) }) else { return false }
        // Reject substantial source loss near the four edges of the already safe crop.
        for y in 0..<height {
            guard points[y * width].x <= 0.09, points[y * width + width - 1].x >= 0.91 else { return false }
        }
        for x in 0..<width {
            guard points[x].y <= 0.09, points[(height - 1) * width + x].y >= 0.91 else { return false }
        }
        // A bilinear cell has an affine determinant: checking all corners rejects folds
        // anywhere inside the cell, not merely at its center.
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let a = points[y * width + x], b = points[y * width + x + 1]
                let c = points[(y + 1) * width + x], d = points[(y + 1) * width + x + 1]
                for (u, v) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                    let dx = Point(x: ((b.x-a.x)*(1-v)+(d.x-c.x)*v)*Double(width-1),
                                   y: ((b.y-a.y)*(1-v)+(d.y-c.y)*v)*Double(width-1))
                    let dy = Point(x: ((c.x-a.x)*(1-u)+(d.x-b.x)*u)*Double(height-1),
                                   y: ((c.y-a.y)*(1-u)+(d.y-b.y)*u)*Double(height-1))
                    let det = dx.x * dy.y - dx.y * dy.x
                    let trace = dx.x*dx.x + dx.y*dx.y + dy.x*dy.x + dy.y*dy.y
                    let disc = max(0, trace*trace - 4*det*det).squareRoot()
                    let minimumScale = max(0, (trace-disc)/2).squareRoot()
                    let maximumScale = max(0, (trace+disc)/2).squareRoot()
                    guard det > 0.20, det < 3.0, minimumScale >= 0.35, maximumScale <= 2.5 else { return false }
                }
            }
        }
        return true
    }

    func sample(x: Double, y: Double) -> Point {
        let gx = min(1, max(0, x)) * Double(width-1)
        let gy = min(1, max(0, y)) * Double(height-1)
        let x0 = min(width-2, Int(gx)), y0 = min(height-2, Int(gy))
        let u = gx - Double(x0), v = gy - Double(y0)
        let a = points[y0*width+x0], b = points[y0*width+x0+1]
        let c = points[(y0+1)*width+x0], d = points[(y0+1)*width+x0+1]
        return Point(x: (a.x*(1-u)+b.x*u)*(1-v)+(c.x*(1-u)+d.x*u)*v,
                     y: (a.y*(1-u)+b.y*u)*(1-v)+(c.y*(1-u)+d.y*u)*v)
    }
}

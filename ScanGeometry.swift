import Foundation

/// Portable pixel algorithms, shared by the iOS pipeline and command-line tests.
/// Coordinates and raster rows use a top-left origin throughout.
enum ScanGeometry {
    struct Surface {
        let mask: [UInt8]
        let contour: [CGPoint]
        let bounds: CGRect
        let confidence: Double
        let clippedEdges: [String]
    }

    static func summedArea(_ pixels: [Double], width: Int, height: Int) -> [Double] {
        var table = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += pixels[y * width + x]
                table[(y + 1) * (width + 1) + x + 1] = table[y * (width + 1) + x + 1] + row
            }
        }
        return table
    }

    static func sum(_ table: [Double], width: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
        let stride = width + 1
        return table[y1 * stride + x1] - table[y0 * stride + x1]
            - table[y1 * stride + x0] + table[y0 * stride + x0]
    }

    private static func morphology(_ mask: [UInt8], width: Int, height: Int,
                                   radius: Int, dilate: Bool) -> [UInt8] {
        let table = summedArea(mask.map(Double.init), width: width, height: height)
        var result = mask
        for y in 0..<height {
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
                let count = sum(table, width: width, x0: x0, y0: y0, x1: x1, y1: y1)
                result[y * width + x] = (dilate ? count > 0 : count >= Double((x1-x0)*(y1-y0))) ? 1 : 0
            }
        }
        return result
    }

    /// A deliberately conservative surface proposal, not semantic AI segmentation.
    /// Closing bridges small letter strokes; connected components reject isolated keys.
    /// The selected component's holes are filled but its external silhouette is retained.
    static func segment(rgba: [UInt8], width: Int, height: Int) -> Surface? {
        guard width >= 16, height >= 16, rgba.count == width * height * 4 else { return nil }
        let count = width * height
        var luminance = [Double](repeating: 0, count: count)
        var central: [Double] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, p = i * 4
                let r = Double(rgba[p]), g = Double(rgba[p+1]), b = Double(rgba[p+2])
                luminance[i] = 0.299*r + 0.587*g + 0.114*b
                if x > width/6 && x < width*5/6 && y > height/6 && y < height*5/6 {
                    central.append(luminance[i])
                }
            }
        }
        central.sort()
        guard let paper = central.dropFirst(central.count * 3 / 4).first, paper > 115 else { return nil }
        let threshold = max(95, paper - 42)
        var mask = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let p = i*4
            let channels = [Int(rgba[p]), Int(rgba[p+1]), Int(rgba[p+2])]
            let spread = (channels.max() ?? 0) - (channels.min() ?? 0)
            mask[i] = luminance[i] >= threshold && spread < 85 ? 1 : 0
        }
        let radius = max(1, min(width, height)/80)
        mask = morphology(mask, width: width, height: height, radius: radius, dilate: true)
        mask = morphology(mask, width: width, height: height, radius: radius, dilate: false)
        var visited = [Bool](repeating: false, count: count)
        var best: [Int] = [], bestScore = 0.0
        for seed in 0..<count where mask[seed] == 1 && !visited[seed] {
            var queue = [seed], cursor = 0
            visited[seed] = true
            var sumX = 0, sumY = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % width, y = i / width
                sumX += x; sumY += y
                var neighbors: [Int] = []
                if x > 0 { neighbors.append(i-1) }
                if x+1 < width { neighbors.append(i+1) }
                if y > 0 { neighbors.append(i-width) }
                if y+1 < height { neighbors.append(i+width) }
                for n in neighbors where !visited[n] && mask[n] == 1 {
                    visited[n] = true; queue.append(n)
                }
            }
            let cx = Double(sumX)/Double(queue.count * width)
            let cy = Double(sumY)/Double(queue.count * height)
            let score = Double(queue.count) * max(0.1, 1 - hypot(cx-0.5, cy-0.5))
            if score > bestScore { best = queue; bestScore = score }
        }
        guard best.count > count/8 else { return nil }
        mask = [UInt8](repeating: 0, count: count)
        for i in best { mask[i] = 1 }
        // Flood exterior background from all four borders to preserve holes as paper.
        visited = [Bool](repeating: false, count: count)
        var queue: [Int] = []
        for i in 0..<count where (i < width || i >= count-width || i % width == 0 || i % width == width-1) && mask[i] == 0 {
            visited[i] = true; queue.append(i)
        }
        var cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            let x = i % width, y = i / width
            var neighbors: [Int] = []
            if x > 0 { neighbors.append(i-1) }
            if x+1 < width { neighbors.append(i+1) }
            if y > 0 { neighbors.append(i-width) }
            if y+1 < height { neighbors.append(i+width) }
            for n in neighbors where !visited[n] && mask[n] == 0 {
                visited[n] = true; queue.append(n)
            }
        }
        for i in 0..<count where !visited[i] { mask[i] = 1 }
        var left = [Int](repeating: width, count: height)
        var right = [Int](repeating: -1, count: height)
        for y in 0..<height {
            for x in 0..<width where mask[y*width+x] == 1 {
                left[y] = min(left[y], x); right[y] = max(right[y], x)
            }
        }
        let rows = (0..<height).filter { right[$0] >= left[$0] }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        let minX = rows.map { left[$0] }.min()!, maxX = rows.map { right[$0] }.max()!
        let bounds = CGRect(x: Double(minX)/Double(width), y: Double(top)/Double(height),
                            width: Double(maxX-minX+1)/Double(width), height: Double(bottom-top+1)/Double(height))
        guard bounds.width > 0.25, bounds.height > 0.25 else { return nil }
        // Row envelopes retain bowed sides. The crop uses the enclosing bounds to avoid
        // cutting hidden text at an occlusion; no invented pixels fill the photograph.
        var sampled = rows.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        if sampled.last != bottom { sampled.append(bottom) }
        var contour = sampled.map { CGPoint(x: Double(left[$0])/Double(width), y: Double($0)/Double(height)) }
        contour += sampled.reversed().map { CGPoint(x: Double(right[$0]+1)/Double(width), y: Double($0+1)/Double(height)) }
        var edges: [String] = []
        if minX <= 1 { edges.append("sinistro") }
        if maxX >= width-2 { edges.append("destro") }
        if top <= 1 { edges.append("superiore") }
        if bottom >= height-2 { edges.append("inferiore") }
        var contrast: [Double] = []
        for y in rows {
            if left[y] > 3 { contrast.append(abs(luminance[y*width+left[y]+min(3,right[y]-left[y])] - luminance[y*width+left[y]-3])) }
            if right[y] < width-4 { contrast.append(abs(luminance[y*width+right[y]-min(3,right[y]-left[y])] - luminance[y*width+right[y]+3])) }
        }
        let boundaryContrast = contrast.isEmpty ? 0 : contrast.reduce(0,+)/Double(contrast.count)
        let area = Double(mask.reduce(0) { $0 + Int($1) })/Double(count)
        let fill = area/Double(bounds.width*bounds.height)
        // Heuristic score, NOT a calibrated probability. Uniform/edge-clipped scenes and
        // irregular silhouettes require review rather than automatic destructive cropping.
        var confidence = 0.35 + min(0.35, boundaryContrast/180) + min(0.20, fill*0.20)
        if !edges.isEmpty { confidence -= 0.22 }
        if fill < 0.70 { confidence -= 0.18 }
        if area > 0.90 { confidence = min(confidence, 0.40) }
        return Surface(mask: mask, contour: contour, bounds: bounds,
                       confidence: max(0, min(0.95, confidence)), clippedEdges: edges)
    }

    struct DewarpCurve {
        /// Source displacement in analysis pixels at uniformly spaced horizontal samples.
        let offsets: [Double]
        let referenceHeight: Int
        let confidence: Double
        let improvement: Double
    }

    static func correlation(_ a: [Double], _ b: [Double], shift: Int, range: Range<Int>) -> Double {
        let indexes = range.filter { $0+shift >= 0 && $0+shift < b.count }
        guard indexes.count > 8 else { return -1 }
        let ma = indexes.reduce(0.0) { $0+a[$1] }/Double(indexes.count)
        let mb = indexes.reduce(0.0) { $0+b[$1+shift] }/Double(indexes.count)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for y in indexes {
            let x = a[y]-ma, z = b[y+shift]-mb
            ab += x*z; aa += x*x; bb += z*z
        }
        return aa*bb > 1e-9 ? ab/sqrt(aa*bb) : -1
    }

    /// Detects a gentle, horizontally varying vertical displacement of repeated text rows.
    /// It cannot recover hidden characters, horizontal compression, or full 3-D page shape.
    /// Independent vertical bands must agree, reducing accidental matches on photos/tables.
    static func estimateDewarp(gray: [Double], width: Int, height: Int) -> DewarpCurve? {
        guard width >= 100, height >= 160, gray.count == width*height else { return nil }
        let table = summedArea(gray, width: width, height: height)
        var ink = [Double](repeating: 0, count: gray.count)
        let radius = max(5, width/50)
        for y in 0..<height {
            for x in 0..<width {
                let x0=max(0,x-radius), x1=min(width,x+radius+1)
                let y0=max(0,y-radius), y1=min(height,y+radius+1)
                let local = sum(table,width:width,x0:x0,y0:y0,x1:x1,y1:y1)/Double((x1-x0)*(y1-y0))
                ink[y*width+x] = max(0, local-gray[y*width+x]-15)
            }
        }
        let strips = 9
        var profiles = [[Double]]()
        for s in 0..<strips {
            let center = Double(s+1)/Double(strips+1)*Double(width-1)
            let x0=max(0,Int(center)-width/16), x1=min(width,Int(center)+width/16+1)
            var p=[Double](repeating:0,count:height)
            for y in 1..<(height-1) {
                for x in x0..<x1 { p[y] += ink[y*width+x] }
                p[y] /= Double(x1-x0)
            }
            let raw=p
            for y in 1..<(height-1) { p[y]=(raw[y-1]+2*raw[y]+raw[y+1])/4 }
            profiles.append(p)
        }
        let ref = profiles[strips/2]
        let range = (height/10)..<(height*9/10)
        let mean = range.reduce(0.0) { $0+ref[$1] }/Double(range.count)
        var peaks = 0
        for y in (range.lowerBound+1)..<(range.upperBound-1) where ref[y] > max(2,mean*1.6) && ref[y] > ref[y-1] && ref[y] >= ref[y+1] { peaks += 1 }
        guard peaks >= 8 else { return nil }
        let maxShift = max(3,min(18,height/40))
        var offsets=[Double](repeating:0,count:strips), scores=[Double](repeating:0,count:strips)
        var gains=[Double](repeating:0,count:strips)
        for s in 0..<strips {
            if s == strips/2 { scores[s]=1; continue }
            var matches: [(Int,Double)] = []
            for shift in (-maxShift)...maxShift {
                matches.append((shift,correlation(ref,profiles[s],shift:shift,range:range)))
            }
            guard let best=matches.max(by: { $0.1 < $1.1 }), best.1 >= 0.50,
                  abs(best.0) < maxShift else { return nil }
            // Disagreeing bands indicate local content variation rather than a stable bow.
            var bandShifts: [Int] = []
            for band in 0..<3 {
                let lo=range.lowerBound+range.count*band/3
                let hi=range.lowerBound+range.count*(band+1)/3
                let bandRange=lo..<hi
                let choices=((-maxShift)...maxShift).map { ($0,correlation(ref,profiles[s],shift:$0,range:bandRange)) }
                if let b=choices.max(by: { $0.1 < $1.1 }), b.1 >= 0.40 { bandShifts.append(b.0) }
            }
            guard bandShifts.count == 3, bandShifts.allSatisfy({ abs($0-best.0) <= 2 }) else { return nil }
            offsets[s]=Double(best.0); scores[s]=best.1
            gains[s]=best.1-correlation(ref,profiles[s],shift:0,range:range)
        }
        // A horizontal text margin has no usable profile. Refuse instead of extrapolating
        // unbounded corrections into the gutter. This intentionally rejects many photos.
        let slopeLimit=0.14*Double(width)/Double(strips-1)
        for s in 1..<strips where abs(offsets[s]-offsets[s-1]) > slopeLimit { return nil }
        let left=offsets[0], right=offsets[strips-1]
        let curvature = offsets.enumerated().map { abs($0.element-(left+(right-left)*Double($0.offset)/Double(strips-1))) }.max() ?? 0
        guard curvature >= 1.5, gains.reduce(0,+)/Double(strips) >= 0.08 else { return nil }
        // Smooth one sample to avoid piecewise jagged displacement; preserve endpoints.
        let raw=offsets
        for s in 1..<(strips-1) { offsets[s]=(raw[s-1]+2*raw[s]+raw[s+1])/4 }
        let extended = [offsets[0]] + offsets + [offsets[strips-1]]
        return DewarpCurve(offsets:extended, referenceHeight:height,
                           confidence:scores.min() ?? 0, improvement:gains.reduce(0,+)/Double(strips))
    }

    static func displacement(_ offsets: [Double], fraction: Double) -> Double {
        guard !offsets.isEmpty else { return 0 }
        let p=max(0,min(1,fraction))*Double(offsets.count-1)
        let low=Int(p), high=min(offsets.count-1,low+1), t=p-Double(low)
        return offsets[low]*(1-t)+offsets[high]*t
    }
}

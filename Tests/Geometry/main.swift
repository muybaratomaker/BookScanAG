import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}

func photo(width: Int, height: Int, paper: (Int,Int)->Bool) -> [UInt8] {
    var data=[UInt8](repeating:255,count:width*height*4)
    for y in 0..<height {
        for x in 0..<width {
            let value: UInt8 = paper(x,y) ? 235 : 60
            for c in 0..<3 { data[(y*width+x)*4+c]=value }
        }
    }
    return data
}
let w=192, h=256
let surface=ScanGeometry.segment(rgba:photo(width:w,height:h) { x,y in
    x >= 22 && x < 170 && y >= 24 && y < 232
},width:w,height:h)!
check(surface.confidence >= 0.80,"Contrasting page accepted")
check(surface.clippedEdges.isEmpty,"Contained page has no clipped edges")
check(abs(surface.bounds.minX-22.0/192)<0.01,"Crop preserves left edge")
check(surface.bounds.maxX >= 170.0/192,"Crop preserves right edge")
let uniform=ScanGeometry.segment(rgba:[UInt8](repeating:235,count:w*h*4),width:w,height:h)!
check(uniform.confidence < 0.8,"Uniform desk cannot trigger confident crop")
check(uniform.clippedEdges.count == 4,"Clipped page identifies all edges")
let dark=ScanGeometry.segment(rgba:[UInt8](repeating:50,count:w*h*4),width:w,height:h)
check(dark == nil,"Dark frame rejected")
let curved=ScanGeometry.segment(rgba:photo(width:w,height:h) { x,y in
    let bend=Int(10*pow((Double(y)-128)/104,2))
    return y >= 24 && y < 232 && x >= 22+bend && x < 170-bend
},width:w,height:h)!
check(curved.contour.count > 20,"Curved mask produces detailed contour")
check(Set(curved.contour.map { Int($0.x*192) }).count > 5,"Contour follows curved sides")
var text=photo(width:w,height:h) { x,y in x >= 22 && x < 170 && y >= 24 && y < 232 }
for y in stride(from:40,to:220,by:12) {
    for x in 35..<155 {
        for c in 0..<3 { text[(y*w+x)*4+c]=20 }
    }
}
let withText=ScanGeometry.segment(rgba:text,width:w,height:h)!
check(withText.mask[100*w+100] == 1,"Text holes retained in page mask")
check(abs(withText.bounds.width-surface.bounds.width)<0.01,"Text does not shrink crop")
check(ScanGeometry.segment(rgba:[],width:w,height:h) == nil,"Invalid raster rejected")
check(ScanGeometry.displacement([0,10,0],fraction:0.25)==5,"Displacement interpolates")
check(ScanGeometry.displacement([2,10],fraction:-1)==2,"Displacement clamps outside domain")
let dw=400, dh=600
check(ScanGeometry.estimateDewarp(gray:[Double](repeating:235,count:dw*dh),width:dw,height:dh) == nil,"Blank page not dewarped")
func lines(curved: Bool) -> [Double] {
    var image=[Double](repeating:235,count:dw*dh)
    // Vary spacings to avoid artificially perfect periodic shift matches.
    let rows=[48,68,91,116,143,172,204,239,276,316,359,405,454,506,550]
    for x in 10..<(dw-10) {
        let shift=curved ? Int((9*pow((Double(x)/Double(dw)-0.5)*2,2)).rounded()) : 0
        for row in rows {
            for dy in 0..<3 { image[(row+shift+dy)*dw+x]=30 }
        }
    }
    return image
}
check(ScanGeometry.estimateDewarp(gray:lines(curved:false),width:dw,height:dh) == nil,"Straight lines not unnecessarily warped")
let curve=ScanGeometry.estimateDewarp(gray:lines(curved:true),width:dw,height:dh)
check(curve != nil,"Synthetic bowed rows yield a correction")
if let curve {
    let before=(0..<dw).map { 9*pow((Double($0)/Double(dw)-0.5)*2,2) }
    let after=(0..<dw).map { before[$0]-ScanGeometry.displacement(curve.offsets,fraction:Double($0)/Double(dw-1)) }
    let central=(dw/8)..<(dw*7/8)
    let originalRange=central.map { before[$0] }.max()! - central.map { before[$0] }.min()!
    let correctedRange=central.map { after[$0] }.max()! - central.map { after[$0] }.min()!
    check(correctedRange < originalRange*0.5,"Correction halves synthetic central row bow")
    print(String(format:"Synthetic row range: %.3f -> %.3f analysis pixels",originalRange,correctedRange))
}
print("\(checks) geometry checks passed. Synthetic fixtures only; no real-photo validation.")

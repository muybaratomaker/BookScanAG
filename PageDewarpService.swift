import UIKit

struct PageDewarpResult {
    let image: UIImage?
    let applied: Bool
    let message: String
}

/// Conservative classical fallback: align repeated text-row profiles across columns.
/// This is a limited geometric correction, not a trained model or full 3-D reconstruction.
final class PageDewarpService {
    private lazy var neural = UVDocDewarpModel()
    func correct(_ image: UIImage) -> PageDewarpResult {
        let upright = ScanRaster.upright(image)
        if let corrected = neural.correct(upright) {
            return PageDewarpResult(image: corrected, applied: true,
                                   message: "UVDoc · verifica il testo prima di usare la correzione.")
        }
        guard let cg = upright.cgImage,
              let analysis = ScanRaster(cgImage: cg, maxDimension: 720),
              let curve = ScanGeometry.estimateDewarp(gray: analysis.gray,
                                                     width: analysis.width, height: analysis.height) else {
            return PageDewarpResult(image: nil, applied: false,
                                   message: "Curvatura non stimabile con affidabilità: conservata la pagina senza correzione.")
        }
        // Only one photograph is decoded at once. The full original remains on disk.
        guard let source = ScanRaster(cgImage: cg, maxDimension: 2800) else {
            return PageDewarpResult(image: nil, applied: false, message: "Immagine non elaborabile; originale conservato.")
        }
        let scale = Double(source.height)/Double(curve.referenceHeight)
        let padding = Int(ceil((curve.offsets.map { abs($0) }.max() ?? 0)*scale))+2
        let outputHeight = source.height+2*padding
        var output = [UInt8](repeating: 255, count: source.width*outputHeight*4)
        for x in 0..<source.width {
            let shift = ScanGeometry.displacement(curve.offsets,
                                                  fraction: Double(x)/Double(max(1,source.width-1)))*scale
            for y in 0..<outputHeight {
                let sourceY = Double(y-padding)+shift
                guard sourceY >= 0, sourceY <= Double(source.height-1) else { continue }
                let y0=Int(sourceY), y1=min(source.height-1,y0+1), t=sourceY-Double(y0)
                let a=(y0*source.width+x)*4, b=(y1*source.width+x)*4, target=(y*source.width+x)*4
                for channel in 0..<3 {
                    let value=Double(source.bytes[a+channel])*(1-t)+Double(source.bytes[b+channel])*t
                    output[target+channel]=UInt8(max(0,min(255,value.rounded())))
                }
            }
        }
        guard let corrected=ScanRaster.image(bytes:output,width:source.width,height:outputHeight) else {
            return PageDewarpResult(image:nil,applied:false,message:"Correzione non riuscita; originale conservato.")
        }
        return PageDewarpResult(image:corrected,applied:true,
                               message:"Correzione geometrica delle righe applicata. Controlla testo piccolo e rilegatura prima di esportare.")
    }
}

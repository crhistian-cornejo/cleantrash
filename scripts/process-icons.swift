// Converts Nano Banana renders (object on pure black) into transparent, trimmed, square 512px PNGs.
// usage: swift scripts/process-icons.swift <inputDir> <outputDir>
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: process-icons <in> <out>"); exit(1) }
let inDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func process(_ url: URL) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("skip \(url.lastPathComponent)"); return }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Key out the black backdrop: anything ≥ 44 luminance-ish is opaque; the dark ramp below that
    // is treated as glow over black and un-premultiplied so edges stay luminous on any backdrop.
    let lo = 7.0, hi = 44.0
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let m = max(r, g, b)
            let a = m <= lo ? 0 : min(1, (m - lo) / (hi - lo))
            if a < 1 {
                // premultipliedLast storage: keep rgb (already ≤ a*255 scale is fine for glow), set alpha.
                let scale = a > 0 ? min(1, a * 255 / max(m, 1)) : 0
                px[i] = UInt8(min(255, r * scale)); px[i + 1] = UInt8(min(255, g * scale)); px[i + 2] = UInt8(min(255, b * scale))
                px[i + 3] = UInt8(a * 255)
            }
            if a > 0.08 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxX > minX, maxY > minY, let keyed = ctx.makeImage() else { print("empty \(url.lastPathComponent)"); return }

    let bw = maxX - minX + 1, bh = maxY - minY + 1
    // CGContext rows are top-down in memory but cropping uses image coordinates (top-left origin) — same here.
    guard let cropped = keyed.cropping(to: CGRect(x: minX, y: minY, width: bw, height: bh)) else { return }
    let side = 512, inset = 512.0 * 0.04
    let out = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.interpolationQuality = .high
    let avail = Double(side) - inset * 2
    let s = avail / Double(max(bw, bh))
    let dw = Double(bw) * s, dh = Double(bh) * s
    out.draw(cropped, in: CGRect(x: (Double(side) - dw) / 2, y: (Double(side) - dh) / 2, width: dw, height: dh))
    let dest = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
    let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, out.makeImage()!, nil)
    CGImageDestinationFinalize(d)
    print("ok \(dest.lastPathComponent) bbox \(bw)x\(bh)")
}

let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []
for f in files where f.pathExtension.lowercased() == "png" { process(f) }

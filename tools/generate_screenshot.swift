// Renders docs/screenshot.png — an approximation of CPUPulse in the menu bar,
// using the same AppKit drawing the app uses. Run: swift generate_screenshot.swift
import Cocoa

let scale: CGFloat = 2
let W: CGFloat = 360, H: CGFloat = 24

// Plausible sample histories (0...1), newest last.
let cpu: [Double] = [0.10,0.12,0.11,0.14,0.22,0.35,0.30,0.25,0.40,0.62,0.78,0.71,0.55,0.48,
                     0.52,0.44,0.33,0.28,0.31,0.46,0.60,0.73,0.88,0.80,0.66,0.52,0.41,0.37,
                     0.30,0.26,0.24,0.29,0.38,0.50,0.47,0.39,0.33,0.44,0.58,0.49,0.36,0.31,
                     0.28,0.35,0.42,0.55,0.63,0.57,0.45,0.38,0.34,0.41,0.52,0.60,0.54,0.43,
                     0.37,0.33,0.39,0.46]
let mem: [Double] = [0.58,0.59,0.59,0.60,0.61,0.62,0.62,0.63,0.64,0.66,0.67,0.67,0.66,0.67,
                     0.68,0.68,0.69,0.69,0.70,0.71,0.72,0.72,0.73,0.74,0.74,0.73,0.74,0.74,
                     0.75,0.75,0.76,0.76,0.77,0.77,0.76,0.77,0.78,0.78,0.79,0.79,0.78,0.79,
                     0.80,0.80,0.81,0.81,0.80,0.81,0.82,0.82,0.83,0.83,0.82,0.83,0.84,0.84,
                     0.85,0.84,0.85,0.86]
let maxSamples = 60

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Menu-bar background (dark).
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Clock at the far right (for menu-bar context).
let clockText = "Mon Nov 24   11:48"
let clockAttrs: [NSAttributedString.Key: Any] = [
    .foregroundColor: NSColor.white,
    .font: NSFont.systemFont(ofSize: 11, weight: .regular)]
let clockSize = (clockText as NSString).size(withAttributes: clockAttrs)
let clockX = W - 10 - clockSize.width
(clockText as NSString).draw(at: NSPoint(x: clockX, y: (H - clockSize.height)/2),
                             withAttributes: clockAttrs)

// The CPUPulse graph, just left of the clock.
let gW: CGFloat = 54, gH: CGFloat = 18
let gx = clockX - 14 - gW
let gy = (H - gH) / 2
let pad: CGFloat = 1.5
let w = gW - pad*2, h = gH - pad*2

func point(_ hist: [Double], _ i: Int) -> NSPoint {
    let step = w / CGFloat(maxSamples - 1)
    return NSPoint(x: gx + pad + CGFloat(i)*step, y: gy + pad + CGFloat(hist[i])*h)
}
func hline(_ frac: CGFloat) {
    let y = gy + pad + frac*h
    let p = NSBezierPath(); p.lineWidth = 0.5
    p.move(to: NSPoint(x: gx+pad, y: y)); p.line(to: NSPoint(x: gx+pad+w, y: y))
    NSColor.white.withAlphaComponent(0.30).setStroke(); p.stroke()
}
func series(_ hist: [Double], _ color: NSColor, fill: Bool, lineWidth: CGFloat) {
    let n = hist.count
    if fill {
        let area = NSBezierPath()
        area.move(to: NSPoint(x: point(hist,0).x, y: gy+pad))
        for i in 0..<n { area.line(to: point(hist,i)) }
        area.line(to: NSPoint(x: point(hist,n-1).x, y: gy+pad)); area.close()
        color.withAlphaComponent(0.18).setFill(); area.fill()
    }
    let line = NSBezierPath(); line.lineWidth = lineWidth; line.lineJoinStyle = .round
    line.move(to: point(hist,0))
    for i in 1..<n { line.line(to: point(hist,i)) }
    color.setStroke(); line.stroke()
}

hline(0.0); hline(1.0)
series(mem, .systemGreen, fill: false, lineWidth: 1.8)   // green = normal pressure
series(cpu, .white,       fill: true,  lineWidth: 1.2)

NSGraphicsContext.restoreGraphicsState()

let outDir = "docs"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "\(outDir)/screenshot.png"))
print("wrote \(outDir)/screenshot.png  (\(Int(W*scale))x\(Int(H*scale)) px)")

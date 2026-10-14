// Renders fileCommander brand assets with AppKit (no third-party tools).
//   swift Render.swift png <in.svg> <out.png> <width> [height]
//   swift Render.swift wordmark <mark.svg> <light|dark> <out.png> <out.svg>
import AppKit

func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func svg(_ path: String) -> NSImage {
    guard let img = NSImage(contentsOfFile: path) else { fatalError("can't read \(path)") }
    return img
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "png":
    let img = svg(args[2])
    let w = Int(args[4])!
    let h = args.count > 5 ? Int(args[5])! : w
    save(bitmap(w, h) { img.draw(in: NSRect(x: 0, y: 0, width: w, height: h)) }, args[3])

case "opaque":
    // Square PNG flattened onto a solid colour (Apple touch icons must be opaque).
    let img = svg(args[2])
    let s = Int(args[4])!
    let hex = UInt32(args[5].dropFirst(), radix: 16)!
    let bg = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                     blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    save(bitmap(s, s) {
        bg.setFill()
        NSRect(x: 0, y: 0, width: s, height: s).fill()
        img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    }, args[3])

case "wordmark":
    // Mark + "fileCommander" set in Avenir Next (ships with macOS). Light = for light backgrounds.
    let mark = svg(args[2])
    let dark = args[3] == "dark"
    let height = 256.0, markSize = 200.0, gap = 44.0, pad = 28.0
    let fileColor = dark ? NSColor(srgbRed: 0.66, green: 0.70, blue: 0.90, alpha: 1) : NSColor(srgbRed: 0.35, green: 0.39, blue: 0.57, alpha: 1)
    let cmdColor = dark ? NSColor.white : NSColor(srgbRed: 0.08, green: 0.10, blue: 0.24, alpha: 1)
    let size = 132.0
    let text = NSMutableAttributedString(string: "file", attributes: [
        .font: NSFont(name: "AvenirNext-Medium", size: size)!, .foregroundColor: fileColor, .kern: -2.0])
    text.append(NSAttributedString(string: "Commander", attributes: [
        .font: NSFont(name: "AvenirNext-Bold", size: size)!, .foregroundColor: cmdColor, .kern: -2.5]))
    let textSize = text.size()
    let width = Int(ceil(pad + markSize + gap + textSize.width + pad))
    let rep = bitmap(width, Int(height)) {
        mark.draw(in: NSRect(x: pad, y: (height - markSize) / 2, width: markSize, height: markSize))
        // Optically centre on the x-height band rather than the full line box.
        text.draw(at: NSPoint(x: pad + markSize + gap, y: (height - textSize.height) / 2 - 4))
    }
    save(rep, args[4])

    // SVG twin: the mark inlined, text live (falls back to similar fonts where Avenir Next is missing).
    var markSVG = try! String(contentsOfFile: args[2], encoding: .utf8)
    // Drop comments (they can span lines), then the outer <svg> element.
    let comments = try! NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])
    markSVG = comments.stringByReplacingMatches(in: markSVG, range: NSRange(markSVG.startIndex..., in: markSVG), withTemplate: "")
    let body = markSVG.components(separatedBy: "\n").filter {
        !$0.hasPrefix("<svg") && !$0.hasPrefix("</svg") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }.joined(separator: "\n")
    let scale = markSize / 824
    let fontStack = "'Avenir Next', Avenir, 'Nunito Sans', 'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
    let hex = { (c: NSColor) -> String in
        let s = c.usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }
    let out = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(Int(height))" width="\(width)" height="\(Int(height))">
      <!-- fileCommander logo (\(dark ? "for dark backgrounds" : "for light backgrounds")). Text is live: set in Avenir Next. -->
      <g transform="translate(\(pad - 100 * scale) \((height - markSize) / 2 - 100 * scale)) scale(\(scale))">
    \(body)
      </g>
      <text x="\(pad + markSize + gap)" y="\(height / 2 + size * 0.35)" font-family="\(fontStack)" font-size="\(Int(size))" letter-spacing="-2"><tspan font-weight="500" fill="\(hex(fileColor))">file</tspan><tspan font-weight="700" fill="\(hex(cmdColor))">Commander</tspan></text>
    </svg>
    """
    try! out.write(toFile: args[5], atomically: true, encoding: .utf8)

default:
    print("usage: Render.swift png|wordmark …")
    exit(2)
}

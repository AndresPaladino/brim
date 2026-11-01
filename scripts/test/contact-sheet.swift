// Tiles PNGs into contact sheets with their file names, for reviewing many renders at once.
// Usage: contact-sheet <out prefix> <columns> <max width per tile> <png>...
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let prefix = args[0], columns = Int(args[1])!, tileWidth = CGFloat(Double(args[2])!)
let files = Array(args.dropFirst(3))
let perSheet = columns * 6
for (sheetIndex, start) in stride(from: 0, to: files.count, by: perSheet).enumerated() {
    let batch = Array(files[start..<min(files.count, start + perSheet)])
    let images = batch.map { NSImage(contentsOfFile: $0) }
    // Scale each image to the tile width (renders are 2x, so halve first).
    let sizes = images.map { img -> CGSize in
        guard let img, let rep = img.representations.first else { return CGSize(width: tileWidth, height: 40) }
        let w = CGFloat(rep.pixelsWide) / 2, h = CGFloat(rep.pixelsHigh) / 2
        let scale = min(1, tileWidth / w)
        return CGSize(width: w * scale, height: h * scale)
    }
    let rows = stride(from: 0, to: batch.count, by: columns).map { Array($0..<min(batch.count, $0 + columns)) }
    let rowHeights = rows.map { r in r.map { sizes[$0].height }.max()! + 22 }
    let width = CGFloat(columns) * (tileWidth + 16) + 16
    let height = rowHeights.reduce(16, +) + CGFloat(rows.count) * 12
    let sheet = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
        NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        var y: CGFloat = 16
        for (ri, r) in rows.enumerated() {
            for (ci, i) in r.enumerated() {
                let x = 16 + CGFloat(ci) * (tileWidth + 16)
                images[i]?.draw(in: NSRect(x: x, y: y, width: sizes[i].width, height: sizes[i].height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let name = (batch[i] as NSString).lastPathComponent
                (name as NSString).draw(at: NSPoint(x: x, y: y + sizes[i].height + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
            }
            y += rowHeights[ri] + 12
        }
        return true
    }
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(prefix)-\(sheetIndex + 1).png"))
    print("\(prefix)-\(sheetIndex + 1).png")
}

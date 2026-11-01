// Compares PNGs in two folders pixel by pixel and writes a diff image for each one that changed.
// Build: swiftc -O scripts/test/imgdiff.swift -o <out>
// Usage: imgdiff <expected dir> <actual dir> [diff dir] [--tolerance 8] [--max-ratio 0.001]
// A pixel differs when any channel moves more than `tolerance` (0-255). An image fails when more than
// `max-ratio` of its pixels differ, or when its size changed. Exit code 1 if any image fails or is missing.
import AppKit

struct Bitmap {
    let width: Int, height: Int
    var pixels: [UInt8]

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        width = image.width; height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    func write(to url: URL) {
        var copy = pixels
        copy.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return fallback }
    args.removeSubrange(i...(i + 1))
    return v
}
let tolerance = Int(option("--tolerance", 8))
let maxRatio = option("--max-ratio", 0.001)
guard args.count >= 2 else { print("usage: imgdiff <expected> <actual> [diff dir]"); exit(2) }
let expectedDir = URL(fileURLWithPath: args[0]), actualDir = URL(fileURLWithPath: args[1])
let diffDir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
if let diffDir { try? FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true) }

func pngs(in dir: URL) -> [String] {
    let e = FileManager.default.enumerator(atPath: dir.path)
    var out: [String] = []
    while let f = e?.nextObject() as? String { if f.hasSuffix(".png") { out.append(f) } }
    return out.sorted()
}

let expected = Set(pngs(in: expectedDir)), actual = Set(pngs(in: actualDir))
var failures = 0, passed = 0
for name in expected.union(actual).sorted() {
    guard expected.contains(name) else { print("NEW      \(name)"); failures += 1; continue }
    guard actual.contains(name) else { print("MISSING  \(name)"); failures += 1; continue }
    guard let a = Bitmap(url: expectedDir.appendingPathComponent(name)), let b = Bitmap(url: actualDir.appendingPathComponent(name)) else {
        print("UNREADABLE \(name)"); failures += 1; continue
    }
    guard a.width == b.width, a.height == b.height else {
        print("SIZE     \(name) \(a.width)x\(a.height) -> \(b.width)x\(b.height)"); failures += 1; continue
    }
    var diff = b
    var changed = 0, worst = 0
    for i in stride(from: 0, to: a.pixels.count, by: 4) {
        var d = 0
        for c in 0..<4 { d = max(d, abs(Int(a.pixels[i + c]) - Int(b.pixels[i + c]))) }
        worst = max(worst, d)
        if d > tolerance {
            changed += 1
            diff.pixels[i] = 255; diff.pixels[i + 1] = 0; diff.pixels[i + 2] = 255; diff.pixels[i + 3] = 255
        } else {
            // Faded copy of the image so the magenta stands out.
            for c in 0..<3 { diff.pixels[i + c] = UInt8(Int(b.pixels[i + c]) / 4) }
        }
    }
    let ratio = Double(changed) / Double(a.width * a.height)
    if ratio > maxRatio {
        failures += 1
        print(String(format: "CHANGED  %@  %.3f%% of pixels, max channel delta %d", name, ratio * 100, worst))
        if let diffDir {
            let out = diffDir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            diff.write(to: out)
        }
    } else {
        passed += 1
    }
}
print("\(passed) same, \(failures) different")
exit(failures == 0 ? 0 : 1)

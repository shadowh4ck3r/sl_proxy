// Composites an image onto an opaque square canvas. iOS app icons must not contain alpha,
// and the source artwork is usually a transparent, non-square logo.
//
// usage: swift flatten-icon.swift <input> <output.png> <size> [hexBackground] [inset]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 4, let size = Int(args[3]), size > 0 else {
    fail("usage: flatten-icon.swift <input> <output.png> <size> [hexBackground] [inset]", code: 64)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let hex = args.count > 4 ? args[4].replacingOccurrences(of: "#", with: "") : "0F1014"
let inset = args.count > 5 ? (Double(args[5]) ?? 0.84) : 0.84

func channel(_ offset: Int) -> CGFloat {
    let pair = hex.dropFirst(offset).prefix(2)
    return CGFloat(Int(pair, radix: 16) ?? 0) / 255
}

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot read image at \(inputURL.path)", code: 65)
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
          data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
          space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ),
      let background = CGColor(colorSpace: colorSpace, components: [channel(0), channel(2), channel(4), 1]) else {
    fail("cannot create drawing context", code: 70)
}

context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.interpolationQuality = .high

let canvas = CGFloat(size)
let scale = min(canvas / CGFloat(image.width), canvas / CGFloat(image.height)) * CGFloat(inset)
let width = CGFloat(image.width) * scale
let height = CGFloat(image.height) * scale
context.draw(image, in: CGRect(x: (canvas - width) / 2, y: (canvas - height) / 2, width: width, height: height))

guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot create output image", code: 70)
}
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot write \(outputURL.path)", code: 74)
}

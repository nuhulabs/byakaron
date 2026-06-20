// Generate a multi-resolution template menu bar icon with Bengali character "ব্যা"
// Template images: macOS auto-inverts for dark mode (black → white)
// Packs 1x (22×16) and 2x (44×32) into a single TIFF for Retina displays
import Cocoa

func makeTemplateImage(width: CGFloat, height: CGFloat, fontSize: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let str = "ব্যা" as NSString
        let strSize = str.size(withAttributes: attrs)
        let point = NSPoint(
            x: (rect.width - strSize.width) / 2,
            y: (rect.height - strSize.height) / 2 + 1
        )
        str.draw(at: point, withAttributes: attrs)
        return true
    }
    image.isTemplate = true
    return image
}

// 1x: 22×16 pt at 72 dpi, 2x: 44×32 pt at 144 dpi
let image1x = makeTemplateImage(width: 22, height: 16, fontSize: 13)
let image2x = makeTemplateImage(width: 44, height: 32, fontSize: 26)

// Pack both resolutions into a single TIFF
let rep1x = NSBitmapImageRep(data: image1x.tiffRepresentation!)!
rep1x.size = NSSize(width: 22, height: 16)
let rep2x = NSBitmapImageRep(data: image2x.tiffRepresentation!)!
rep2x.size = NSSize(width: 22, height: 16)  // logical size = 1x; pixel size = 2x

let combined = NSImage(size: NSSize(width: 22, height: 16))
combined.addRepresentation(rep1x)
combined.addRepresentation(rep2x)
combined.isTemplate = true

let tiffData = combined.tiffRepresentation!
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "iconTemplate.tiff"
try! tiffData.write(to: URL(fileURLWithPath: outputPath))
print("Icon written to \(outputPath)")

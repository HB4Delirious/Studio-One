import AppKit

extension NSImage {
    /// The image in a square bitmap `side` pixels across, cropped to its
    /// centre rather than stretched.
    func squareBitmap(side: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let crop = min(size.width, size.height)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side),
             from: NSRect(x: (size.width - crop) / 2, y: (size.height - crop) / 2, width: crop, height: crop),
             operation: .copy, fraction: 1)
        return rep
    }

    func squarePNG(side: Int) -> Data? {
        squareBitmap(side: side)?.representation(using: .png, properties: [:])
    }

    func squareJPEG(side: Int, quality: Double) -> Data? {
        squareBitmap(side: side)?.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Four covers as one, two by two, each cropped square — a playlist's
    /// cover when its first song has none. Nil without four.
    static func mosaic(_ images: [NSImage], side: Int) -> Data? {
        guard images.count >= 4,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let half = CGFloat(side) / 2
        // Reading order: top left, top right, bottom left, bottom right.
        let origins = [CGPoint(x: 0, y: half), CGPoint(x: half, y: half), CGPoint(x: 0, y: 0), CGPoint(x: half, y: 0)]
        for (image, origin) in zip(images, origins) {
            let crop = min(image.size.width, image.size.height)
            image.draw(in: NSRect(origin: origin, size: CGSize(width: half, height: half)),
                       from: NSRect(x: (image.size.width - crop) / 2, y: (image.size.height - crop) / 2,
                                    width: crop, height: crop),
                       operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

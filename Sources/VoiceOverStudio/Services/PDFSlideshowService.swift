//
//  PDFSlideshowService.swift
//  VoiceOverStudio
//
//  Turns a PDF (typically a computer manual) into a narrated slideshow clip.
//  Each page's margins are trimmed to its ink, portrait pages split into
//  upper/lower viewports, and the halves of a page are joined on screen by a
//  short eased scroll. Baking renders the PDF vector-crisp straight into a
//  silent 1080p H.264 movie whose per-segment durations are driven by the
//  narrations — from there the clip behaves like any video attachment.
//
//  Baked movies are "sparse": a still viewport is ONE frame whose duration is
//  the gap to the next frame; only pans render at full frame rate. That keeps
//  a 100-page manual baking in seconds instead of minutes.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import PDFKit

enum PDFSlideshowService {

    static let canvasSize = CGSize(width: 1920, height: 1080)
    static let framesPerSecond: Int32 = 30
    /// Pacing shared by the bake and the view model's timing pass.
    static let panSeconds: Double = 0.8
    static let leadSeconds: Double = 0.3
    static let tailSeconds: Double = 0.7
    static let minimumDwellSeconds: Double = 3.0

    struct SegmentLayout {
        let number: Int
        let page: Int
        /// Crop rect in PDF user space (bottom-left origin) over the page's
        /// content box.
        let crop: CGRect
        /// True when this viewport arrives by panning down from the previous
        /// half of the same page; page boundaries cut instead.
        let scrollsIn: Bool
        /// Full page text — the agent summarizes the half it can see.
        let pageText: String
    }

    struct Layout {
        let pageCount: Int
        let segments: [SegmentLayout]
    }

    struct SegmentTiming {
        /// Span start on the movie timeline (pan included).
        let start: Double
        /// Full on-screen duration: pan + hold.
        let span: Double
        let panSeconds: Double
        /// Where the narration's voice clip is anchored inside the span.
        let narrationStart: Double
    }

    enum SlideshowError: LocalizedError {
        case unreadablePDF
        case noPages
        case renderFailed
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadablePDF:
                return "The PDF could not be opened."
            case .noPages:
                return "The PDF has no usable pages."
            case .renderFailed:
                return "Could not render a PDF page."
            case .writerFailed(let why):
                return "Could not write the slideshow movie: \(why)"
            }
        }
    }

    // MARK: - Layout

    /// Split every page into viewports: wide pages stay whole, portrait pages
    /// become upper and lower halves broken at real whitespace — never
    /// through a text line.
    static func buildLayout(pdfURL: URL) throws -> Layout {
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw SlideshowError.unreadablePDF
        }

        // Running headers and footers are text lines like any other, but they
        // recur on most pages at the top/bottom edge. Left in, the content
        // box spans the whole page and the splitter's widest free band is the
        // body-to-footer whitespace — every other segment becomes a footer
        // sliver. Detect once per document and exclude.
        let furniture = recurringFurniture(in: document)

        var segments: [SegmentLayout] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let edgeBand = mediaBox.height * 0.12
            let lines = lineEntries(page, within: mediaBox)
                .filter { entry in
                    // Furniture matches exactly, or as a fragment: PDFKit may
                    // return "CocoaMojo — examples/othello" and "Page 1 of 35"
                    // as two lines where other pages give one.
                    guard entry.rect.midY > mediaBox.maxY - edgeBand
                        || entry.rect.midY < mediaBox.minY + edgeBand
                    else { return true }
                    if furniture.contains(entry.fingerprint) { return false }
                    return !furniture.contains { major in
                        major.contains(entry.fingerprint) || entry.fingerprint.contains(major)
                    }
                }
                .map(\.rect)
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Text pages: the union of line rects IS the content. Pixel scans
            // key on decoration (page cards, rules, shadows) and can inflate
            // the box to the whole page, which is how blank viewports happen.
            // Image-only pages (no extractable lines) fall back to the scan.
            let content: CGRect
            if let union = lines.first.map({ _ in lines.reduce(lines[0]) { $0.union($1) } }) {
                content = union
            } else {
                content = contentBox(for: page, in: mediaBox)
            }

            let crops: [CGRect]
            if content.width / content.height >= 1.25 {
                crops = [padded(content, within: mediaBox)]
            } else {
                crops = splitAtLineGaps(page, lines: lines, ink: inkMap(for: page, in: mediaBox),
                                        content: content, mediaBox: mediaBox)
            }
            for (halfIndex, crop) in crops.enumerated() {
                segments.append(SegmentLayout(
                    number: segments.count + 1,
                    page: pageIndex + 1,
                    crop: crop,
                    scrollsIn: halfIndex > 0,
                    pageText: text
                ))
            }
        }
        guard !segments.isEmpty else { throw SlideshowError.noPages }
        return Layout(pageCount: document.pageCount, segments: segments)
    }

    private struct LineEntry {
        let fingerprint: String
        let rect: CGRect
    }

    /// Text lines with a recurrence fingerprint: text with digits folded to
    /// '#' so "Page 3 of 35" and "Page 4 of 35" match, kept with bounds.
    private static func lineEntries(_ page: PDFPage, within mediaBox: CGRect) -> [LineEntry] {
        (page.selection(for: mediaBox)?.selectionsByLine() ?? [])
            .compactMap { selection in
                let bounds = selection.bounds(for: page)
                guard !bounds.isEmpty, let text = selection.string else { return nil }
                let fingerprint = String(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        .map { $0.isNumber ? "#" : $0 }
                )
                return LineEntry(fingerprint: fingerprint, rect: bounds)
            }
            .sorted { $0.rect.midY > $1.rect.midY }
    }

    /// Fingerprints of lines recurring on at least half the pages while
    /// sitting in the top or bottom 12% of the page — running furniture.
    private static func recurringFurniture(in document: PDFDocument) -> Set<String> {
        let pageCount = document.pageCount
        guard pageCount >= 4 else { return [] }
        var counts: [String: Int] = [:]
        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let edgeBand = mediaBox.height * 0.12
            var seen = Set<String>()
            for entry in lineEntries(page, within: mediaBox)
            where entry.rect.midY > mediaBox.maxY - edgeBand || entry.rect.midY < mediaBox.minY + edgeBand {
                seen.insert(entry.fingerprint)
            }
            for fingerprint in seen {
                counts[fingerprint, default: 0] += 1
            }
        }
        let threshold = Int((Double(pageCount) / 2).rounded(.up))
        return Set(counts.filter { $0.value >= threshold }.map(\.key))
    }

    /// Margin around the ink so ascenders, descenders and diagram edges sit
    /// inside the viewport instead of being sliced by it. Horizontal margin
    /// is wider so text blocks breathe on screen.
    private static let cropPaddingY: CGFloat = 10
    private static let cropPaddingX: CGFloat = 24

    private static func padded(_ rect: CGRect, within mediaBox: CGRect) -> CGRect {
        rect
            .insetBy(dx: -cropPaddingX, dy: -cropPaddingY)
            .intersection(mediaBox)
    }

    /// Break portrait content at whitespace — provably without slicing a
    /// line. All line rects are merged into ink extents; the whitespace bands
    /// between them are the only legal split positions (PDFKit can return
    /// overlapping line rects, so naive between-consecutive-lines gaps are
    /// not safe). The band whose centre is nearest the content middle wins,
    /// wider bands preferred. A page with no safe band, or a half that would
    /// hold nothing (no lines, no ink), becomes a single viewport instead.
    private static func splitAtLineGaps(
        _ page: PDFPage,
        lines: [CGRect],
        ink: InkMap,
        content: CGRect,
        mediaBox: CGRect
    ) -> [CGRect] {
        func halves(splitAt splitY: CGFloat) -> [CGRect] {
            [
                CGRect(x: content.minX - cropPaddingX,
                       y: splitY,
                       width: content.width + 2 * cropPaddingX,
                       height: content.maxY + cropPaddingY - splitY)
                    .intersection(mediaBox),
                CGRect(x: content.minX - cropPaddingX,
                       y: content.minY - cropPaddingY,
                       width: content.width + 2 * cropPaddingX,
                       height: splitY - (content.minY - cropPaddingY))
                    .intersection(mediaBox)
            ]
        }

        func hasContent(_ rect: CGRect) -> Bool {
            if lines.contains(where: { $0.midY >= rect.minY && $0.midY <= rect.maxY }) {
                return true
            }
            // The ink fallback is for pages with no extractable lines at all
            // (pure images). On text pages it must not rescue a line-less
            // half — that is how footer and margin slivers sneak in.
            return lines.isEmpty && ink.containsInk(in: rect)
        }

        // Ink-free bands: sweep merged line extents bottom-up through content.
        let extents = lines
            .map { (min: $0.minY - 0.5, max: $0.maxY + 0.5) }
            .sorted { $0.min < $1.min }
        var bands: [(center: CGFloat, width: CGFloat)] = []
        var inkEdge = content.minY
        for extent in extents {
            if extent.min > inkEdge + 2 {
                bands.append((center: (inkEdge + extent.min) / 2, width: extent.min - inkEdge))
            }
            inkEdge = max(inkEdge, extent.max)
        }
        if content.maxY > inkEdge + 2 {
            bands.append((center: (inkEdge + content.maxY) / 2, width: content.maxY - inkEdge))
        }

        let middle = content.midY
        // Prefer bands near the vertical middle — the widest band anywhere
        // can be an ending's trailing whitespace, which would hand the whole
        // body to one segment and a sliver to the other.
        let nearMiddle = bands.filter { abs($0.center - middle) <= content.height * 0.30 }
        let pool = nearMiddle.isEmpty ? bands : nearMiddle
        if let best = pool.max(by: { lhs, rhs in
            let lhsScore = lhs.width - abs(lhs.center - middle) * 0.05
            let rhsScore = rhs.width - abs(rhs.center - middle) * 0.05
            return lhsScore < rhsScore
        }) {
            let parts = halves(splitAt: best.center)
            if hasContent(parts[0]), hasContent(parts[1]) { return parts }
        }
        // No safe band, or one half would be empty: one viewport for the page.
        return [padded(content, within: mediaBox)]
    }

    /// Grayscale ink map at low resolution, used to detect real ink inside
    /// regions that have no text lines (diagrams, images) and to refuse
    /// blank viewports.
    struct InkMap {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let scale: Double     // pixels per PDF point
        let pageHeight: Double

        /// Dark ink anywhere inside `rect` (PDF user space)?
        func containsInk(in rect: CGRect, minimumPixels: Int = 4) -> Bool {
            guard width > 1, height > 1, scale > 0, rect.width > 0, rect.height > 0 else {
                return false
            }
            let x0 = max(0, min(width - 1, Int(rect.minX * scale)))
            let x1 = max(0, min(width - 1, Int(rect.maxX * scale)))
            // Memory row 0 is the image's top row; PDF y=0 is the page bottom.
            let yTop = max(0, min(height - 1, Int((pageHeight - rect.maxY) * scale)))
            let yBottom = max(0, min(height - 1, Int((pageHeight - rect.minY) * scale)))
            guard x1 >= x0, yBottom >= yTop else { return false }
            var dark = 0
            for row in yTop...yBottom {
                for column in x0...x1 where pixels[row * width + column] < 210 {
                    dark += 1
                    if dark >= minimumPixels { return true }
                }
            }
            return false
        }
    }

    private static func inkMap(for page: PDFPage, in mediaBox: CGRect) -> InkMap {
        let width = 160
        guard mediaBox.width > 1, mediaBox.height > 1 else {
            return InkMap(pixels: [], width: 0, height: 0, scale: 0, pageHeight: mediaBox.height)
        }
        let scale = Double(width) / mediaBox.width
        let height = max(1, Int((mediaBox.height * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            page.draw(with: .mediaBox, to: context)
        }
        return InkMap(pixels: pixels, width: width, height: height, scale: scale, pageHeight: mediaBox.height)
    }

    /// Pixel scan for the page's ink: render the page small and grayscale,
    /// then take the bounding box of non-paper pixels. Images and diagrams
    /// count, not just text. Falls back to the full page when the page is
    /// essentially blank (divider pages — the agent decides those).
    private static func contentBox(for page: PDFPage, in mediaBox: CGRect) -> CGRect {
        guard mediaBox.width > 1, mediaBox.height > 1 else {
            return mediaBox
        }
        let width = 160
        let scale = Double(width) / mediaBox.width
        let height = max(1, Int((mediaBox.height * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard drew else { return mediaBox }

        var minX = width, maxX = -1, minY = height, maxY = -1
        for row in 0..<height {
            for column in 0..<width {
                if pixels[row * width + column] < 210 {
                    if column < minX { minX = column }
                    if column > maxX { maxX = column }
                    if row < minY { minY = row }
                    if row > maxY { maxY = row }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return mediaBox }

        // Bitmap memory row 0 is the image's top row; PDF space has y=0 at
        // the bottom of the page. Flip back, then convert to page units.
        // The box stays tight on the ink — segment crops add the padding, so
        // insetting here would shave the outermost line edges.
        let topPDF = mediaBox.height - Double(minY) / scale
        let bottomPDF = mediaBox.height - Double(maxY + 1) / scale
        let box = CGRect(
            x: mediaBox.minX + Double(minX) / scale,
            y: bottomPDF,
            width: Double(maxX - minX + 1) / scale,
            height: topPDF - bottomPDF
        )
        let clipped = box.intersection(mediaBox)
        guard !clipped.isNull, clipped.width > 8, clipped.height > 8 else { return mediaBox }
        return clipped
    }

    // MARK: - Viewport rendering

    /// Draw `crop` of `page` fitted into a canvas of `size` over the dark
    /// paper background. Vector: pages stay crisp at zoomed half-page scale.
    /// Clipped to the crop's destination: a page's own white background must
    /// not bleed across the letterbox bars.
    static func renderViewport(_ page: PDFPage, crop: CGRect, in context: CGContext, canvas: CGSize) {
        context.saveGState()
        context.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        let scale = min(canvas.width / crop.width, canvas.height / crop.height)
        let drawnSize = CGSize(width: crop.width * scale, height: crop.height * scale)
        let origin = CGPoint(
            x: (canvas.width - drawnSize.width) / 2,
            y: (canvas.height - drawnSize.height) / 2
        )
        context.clip(to: CGRect(origin: origin, size: drawnSize))
        context.translateBy(x: origin.x - crop.minX * scale, y: origin.y - crop.minY * scale)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }

    /// PNG of one segment's viewport at agent-review size.
    static func writeSegmentPNG(_ record: SlideshowSegmentRecord, document: PDFDocument, to url: URL) throws {
        guard let page = document.page(at: record.page - 1) else { throw SlideshowError.renderFailed }
        let canvas = CGSize(width: 960, height: 540)
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SlideshowError.renderFailed }
        renderViewport(page, crop: record.crop, in: context, canvas: canvas)
        guard let image = context.makeImage() else { throw SlideshowError.renderFailed }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SlideshowError.renderFailed
        }
        try data.write(to: url)
    }

    /// The agent's eyes: one text file per segment (its page's text) and one
    /// PNG of exactly what the viewer will see.
    static func dumpSegmentAssets(segments: [SlideshowSegmentRecord], pdfURL: URL, into directory: URL) throws {
        guard let document = PDFDocument(url: pdfURL) else { throw SlideshowError.unreadablePDF }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for record in segments {
            let stem = String(format: "seg-%03d", record.number)
            let text = document.page(at: record.page - 1).flatMap { $0.string } ?? ""
            try text.write(
                to: directory.appendingPathComponent("\(stem).txt"),
                atomically: true,
                encoding: .utf8
            )
            try writeSegmentPNG(record, document: document, to: directory.appendingPathComponent("\(stem).png"))
        }
    }

    // MARK: - Bake

    /// Write the silent stills movie. `timing` keys are segment numbers; only
    /// non-skipped segments may appear in it. Returns the movie duration.
    @discardableResult
    static func bake(
        pdfURL: URL,
        segments: [SlideshowSegmentRecord],
        timing: [Int: SegmentTiming],
        to output: URL,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> Double {
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw SlideshowError.unreadablePDF
        }
        let included = segments.filter { !$0.skipped }
        guard !included.isEmpty else { throw SlideshowError.noPages }

        typealias PlanEntry = (record: SlideshowSegmentRecord, page: PDFPage?, timing: SegmentTiming)
        var plan: [PlanEntry] = []
        for record in included {
            guard let entryTiming = timing[record.number] else { continue }
            plan.append((record, document.page(at: record.page - 1), entryTiming))
        }
        guard plan.count == included.count, let last = plan.last else {
            throw SlideshowError.noPages
        }
        let totalDuration = last.timing.start + last.timing.span

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: output)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try bakeSync(plan: plan, to: output, totalDuration: totalDuration, progress: progress)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return totalDuration
    }

    private static func bakeSync(
        plan: [(record: SlideshowSegmentRecord, page: PDFPage?, timing: SegmentTiming)],
        to output: URL,
        totalDuration: Double,
        progress: ((Int, Int) -> Void)?
    ) throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(canvasSize.width),
                kCVPixelBufferHeightKey as String: Int(canvasSize.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw SlideshowError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)

        // Every frame gets its OWN buffer from the adaptor's pool. Reusing a
        // small ring of buffers races the encoder — it can still hold a
        // buffer we re-render, and the half-drawn frame (background, no
        // content) then HOLDS on screen for the whole still. Pool allocation
        // only recycles buffers the writer has released, so this is safe.
        func acquireBuffer() throws -> CVPixelBuffer {
            if let pool = adaptor.pixelBufferPool {
                var pooled: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled)
                if let pooled { return pooled }
            }
            var fresh: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &fresh)
            guard let fresh else {
                throw SlideshowError.writerFailed("could not allocate a pixel buffer")
            }
            return fresh
        }

        func renderInto(_ buffer: CVPixelBuffer, page: PDFPage?, crop: CGRect) throws {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let page, let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw SlideshowError.renderFailed
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { throw SlideshowError.renderFailed }
            renderViewport(page, crop: crop, in: context, canvas: canvasSize)
        }

        func append(_ buffer: CVPixelBuffer, atSeconds seconds: Double) throws {
            var attempts = 0
            while !input.isReadyForMoreMediaData {
                if attempts > 25_000 { throw SlideshowError.writerFailed("writer stalled") }
                Thread.sleep(forTimeInterval: 0.004)
                attempts += 1
            }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw SlideshowError.writerFailed(
                    writer.error?.localizedDescription ?? "could not append frame at \(seconds)s"
                )
            }
        }

        var previousCrop: CGRect?
        for (index, entry) in plan.enumerated() {
            progress?(index + 1, plan.count)
            let pan = entry.timing.panSeconds
            if entry.record.scrollsIn, let from = previousCrop {
                // Full-frame-rate eased pan from the previous viewport down to
                // this one; the last step lands exactly on the target crop.
                let steps = max(2, Int((pan * Double(framesPerSecond)).rounded()))
                for step in 0...steps {
                    let fraction = easeInOut(Double(step) / Double(steps))
                    let crop = interpolate(from, entry.record.crop, fraction)
                    let buffer = try acquireBuffer()
                    try renderInto(buffer, page: entry.page, crop: crop)
                    try append(buffer, atSeconds: entry.timing.start + pan * Double(step) / Double(steps))
                }
            } else {
                // A cut (or the very first segment): one still frame that
                // holds until the next frame's timestamp.
                let buffer = try acquireBuffer()
                try renderInto(buffer, page: entry.page, crop: entry.record.crop)
                try append(buffer, atSeconds: entry.timing.start)
            }
            previousCrop = entry.record.crop
        }

        // Sparse streams size each frame's duration from the gap before it,
        // so the track would end one frame after the last append. Close with
        // two timestamps: the total duration, then one frame later — the tail
        // hold lands on the closer and the movie ends at totalDuration + 1
        // frame instead of totalDuration + the whole final gap.
        if let last = plan.last {
            let buffer = try acquireBuffer()
            try renderInto(buffer, page: last.page, crop: last.record.crop)
            try append(buffer, atSeconds: totalDuration)
            let buffer2 = try acquireBuffer()
            try renderInto(buffer2, page: last.page, crop: last.record.crop)
            try append(buffer2, atSeconds: totalDuration + 1.0 / Double(framesPerSecond))
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 600)
        guard writer.status == .completed else {
            throw SlideshowError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }
    }

    // MARK: - Geometry helpers

    private static func easeInOut(_ fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func interpolate(_ from: CGRect, _ to: CGRect, _ fraction: Double) -> CGRect {
        CGRect(
            x: from.origin.x + (to.origin.x - from.origin.x) * fraction,
            y: from.origin.y + (to.origin.y - from.origin.y) * fraction,
            width: from.width + (to.width - from.width) * fraction,
            height: from.height + (to.height - from.height) * fraction
        )
    }
}

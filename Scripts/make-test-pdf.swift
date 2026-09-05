//
//  make-test-pdf.swift
//  VoiceOverStudio
//
//  Writes a synthetic manual-style PDF for testing the slideshow pipeline.
//  Usage: swift make-test-pdf.swift <output.pdf>
//
//  Pages are deliberately varied for layout verification:
//    1. portrait, ink only in the upper half (content-box + flip check)
//    2. portrait, both halves full
//    3. landscape slide (stays a single segment)
//    4. portrait, near blank (content-free — the agent should skip it)
//

import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift make-test-pdf.swift <output.pdf>\n".data(using: .utf8)!)
    exit(2)
}
let outputURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
try? FileManager.default.removeItem(at: outputURL)

var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter portrait

guard let context = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("could not create PDF context\n".data(using: .utf8)!)
    exit(1)
}

func drawText(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
}

func beginPage(_ box: CGRect) {
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(box)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
}

// Page 1 — ink in the upper half only.
var box = mediaBox
beginPage(box)
drawText("Test Manual — Getting Started", at: CGPoint(x: 72, y: 700), size: 24, weight: .bold)
for row in 0..<8 {
    drawText("Upper half line \(row + 1): install the app and open a project.", at: CGPoint(x: 72, y: 660 - CGFloat(row) * 22), size: 12)
}

context.endPDFPage()

// Page 2 — both halves full.
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(box)
context.setFillColor(CGColor(gray: 0, alpha: 1))
drawText("Configuration", at: CGPoint(x: 72, y: 700), size: 24, weight: .bold)
for row in 0..<12 {
    drawText("Setting \(row + 1): adjust the value then save your changes.", at: CGPoint(x: 72, y: 660 - CGFloat(row) * 24), size: 12)
}
drawText("Advanced Options", at: CGPoint(x: 72, y: 360), size: 20, weight: .semibold)
for row in 0..<12 {
    drawText("Advanced \(row + 1): see the reference table before editing.", at: CGPoint(x: 72, y: 324 - CGFloat(row) * 24), size: 12)
}

context.endPDFPage()

// Page 3 — landscape slide (single segment).
box = CGRect(x: 0, y: 0, width: 792, height: 612)
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(box)
context.setFillColor(CGColor(gray: 0, alpha: 1))
drawText("Architecture Overview", at: CGPoint(x: 72, y: 520), size: 28, weight: .bold)
for row in 0..<6 {
    drawText("Slide bullet \(row + 1): the pieces fit together this way.", at: CGPoint(x: 72, y: 470 - CGFloat(row) * 34), size: 16)
}

context.endPDFPage()

// Page 4 — near blank (divider).
box = mediaBox
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(box)
context.setFillColor(CGColor(gray: 0, alpha: 1))
drawText("2", at: CGPoint(x: 300, y: 40), size: 10)

context.endPDFPage()
context.closePDF()

print(outputURL.path)

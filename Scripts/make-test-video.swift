//
//  make-test-video.swift
//  VoiceOverStudio
//
//  Writes a small synthetic movie for testing the video timeline and its
//  AppleScript surface. Usage: swift make-test-video.swift <output.mov> [seconds]
//  No audio track: screen-capture style input, exercises the voice-over-only mix.
//

import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift make-test-video.swift <output.mov> [seconds]\n".data(using: .utf8)!)
    exit(2)
}

let outputURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
let seconds = args.count >= 3 ? (Double(args[2]) ?? 12) : 12
let fps: Int32 = 15
let size = CGSize(width: 640, height: 400)

try? FileManager.default.removeItem(at: outputURL)

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: size.width,
    AVVideoHeightKey: size.height,
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: size.width,
    kCVPixelBufferHeightKey as String: size.height,
])
writer.add(input)
guard writer.startWriting() else {
    FileHandle.standardError.write("writer failed: \(writer.error.map(String.init(describing:)) ?? "?")\n".data(using: .utf8)!)
    exit(1)
}
writer.startSession(atSourceTime: .zero)

let frameCount = Int(Double(fps) * seconds)
for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
    guard let buffer = pixelBuffer else { fatalError("no pixel buffer from pool") }

    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    // Hue cycles every two seconds and a marker band marches downward, so
    // filmstrip thumbnails and scrub positions are visibly distinct.
    let hue = CGFloat(frame % (Int(fps) * 2)) / CGFloat(fps * 2)
    context.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: CGFloat(frame % 20) * 20, width: size.width, height: 8))
    CVPixelBufferUnlockBaseAddress(buffer, [])

    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
}

input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting { semaphore.signal() }
semaphore.wait()

guard writer.status == .completed else {
    FileHandle.standardError.write("finish failed: \(writer.error.map(String.init(describing:)) ?? "?")\n".data(using: .utf8)!)
    exit(1)
}

print("wrote \(outputURL.path) (\(String(format: "%.1f", Double(frameCount) / Double(fps)))s)")

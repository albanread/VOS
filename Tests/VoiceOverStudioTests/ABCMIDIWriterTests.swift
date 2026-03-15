import Foundation
import XCTest
@testable import VoiceOverStudio

final class ABCMIDIWriterTests: XCTestCase {
    private func writeMIDI(_ abc: String) throws -> Data {
        let tune = try ABCParser().parse(abc)
        let tracks = ABCMIDIGenerator().generateMIDI(tune)
        return ABCMIDIWriter().write(tracks: tracks)
    }

    private func parseChunks(_ data: Data) throws -> (format: UInt16, trackCount: UInt16, division: UInt16, tracks: [Data]) {
        XCTAssertGreaterThanOrEqual(data.count, 14)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "MThd")

        let headerLength = readUInt32(data, offset: 4)
        XCTAssertEqual(headerLength, 6)

        let format = readUInt16(data, offset: 8)
        let trackCount = readUInt16(data, offset: 10)
        let division = readUInt16(data, offset: 12)

        var tracks: [Data] = []
        var offset = 14
        while offset + 8 <= data.count {
            XCTAssertEqual(String(decoding: data[offset..<(offset + 4)], as: UTF8.self), "MTrk")
            let length = Int(readUInt32(data, offset: offset + 4))
            let trackStart = offset + 8
            let trackEnd = trackStart + length
            XCTAssertLessThanOrEqual(trackEnd, data.count)
            tracks.append(data.subdata(in: trackStart..<trackEnd))
            offset = trackEnd
        }

        return (format, trackCount, division, tracks)
    }

    func testWriterProducesStandardHeaderAndTrackCount() throws {
        let data = try writeMIDI("""
        X:1
        T:HeaderCheck
        M:4/4
        L:1/8
        K:C
        C
        """)

        let parsed = try parseChunks(data)
        XCTAssertEqual(parsed.format, 1)
        XCTAssertEqual(parsed.trackCount, 2)
        XCTAssertEqual(parsed.division, 480)
        XCTAssertEqual(parsed.tracks.count, 2)
    }

    func testWriterSerializesTempoMetaAndEndOfTrack() throws {
        let data = try writeMIDI("""
        X:1
        T:TempoTrack
        M:3/4
        L:1/8
        Q:90
        K:G
        C
        """)

        let parsed = try parseChunks(data)
        let tempoTrack = try XCTUnwrap(parsed.tracks.first)
        let bytes = [UInt8](tempoTrack)

        XCTAssertTrue(bytes.contains(contentsOf: [0xFF, 0x51, 0x03]))
        XCTAssertTrue(bytes.contains(contentsOf: [0xFF, 0x58, 0x04]))
        XCTAssertTrue(bytes.contains(contentsOf: [0xFF, 0x59, 0x02]))
        XCTAssertTrue(bytes.suffix(3).elementsEqual([0xFF, 0x2F, 0x00]))
    }

    func testWriterEncodesProgramNoteOnNoteOffAndDeltaTimes() throws {
        let data = try writeMIDI("""
        X:1
        T:NoteBytes
        M:4/4
        L:1/8
        K:C
        C
        """)

        let parsed = try parseChunks(data)
        let noteTrack = try XCTUnwrap(parsed.tracks.last)
        let bytes = [UInt8](noteTrack)

        XCTAssertTrue(bytes.starts(with: [0x00, 0xC0, 0x00, 0x00, 0x90, 0x30, 0x50]))
        XCTAssertTrue(bytes.contains(contentsOf: [0x81, 0x70, 0x80, 0x30, 0x00]))
        XCTAssertTrue(bytes.suffix(4).elementsEqual([0x00, 0xFF, 0x2F, 0x00]))
    }

    func testWriterEncodesExplicitVoiceChannelInStatusBytes() throws {
        let data = try writeMIDI("""
        X:1
        T:ExplicitChannelBytes
        M:4/4
        L:1/8
        K:C
        V:1
        %%MIDI channel 6
        C
        """)

        let parsed = try parseChunks(data)
        let noteTrack = try XCTUnwrap(parsed.tracks.last)
        let bytes = [UInt8](noteTrack)

        XCTAssertTrue(bytes.contains(contentsOf: [0x00, 0xC5, 0x00]))
        XCTAssertTrue(bytes.contains(contentsOf: [0x00, 0x95, 0x30, 0x50]))
        XCTAssertTrue(bytes.contains(contentsOf: [0x81, 0x70, 0x85, 0x30, 0x00]))
    }

    func testWriterEncodesPercussionChannelTenStatusBytes() throws {
        let data = try writeMIDI("""
        X:1
        T:PercussionBytes
        M:4/4
        L:1/8
        K:C
        %%MIDI percussion on
        %%MIDI program 24
        C
        """)

        let parsed = try parseChunks(data)
        let noteTrack = try XCTUnwrap(parsed.tracks.last)
        let bytes = [UInt8](noteTrack)

        XCTAssertTrue(bytes.contains(contentsOf: [0x00, 0xC9, 0x18]))
        XCTAssertTrue(bytes.contains(contentsOf: [0x00, 0x99, 0x30, 0x50]))
        XCTAssertTrue(bytes.contains(contentsOf: [0x81, 0x70, 0x89, 0x30, 0x00]))
    }

    func testWriterKeepsPodcastLeadAndBassTracksConcurrent() throws {
        let data = try writeMIDI("""
        X:1
        T:Podcast Intro Jingle
        C:Adaptive Collaborator
        M:4/4
        L:1/8
        Q:1/4=120
        K:C
        %%score (V1 V2)
        V:1 name="Lead"

        |: G2 c2 e2 g2 | f2 d2 B2 G2 | G2 c2 e2 g2 | f e d c G4 |
        |  e g c'2 b a g f | e2 d2 c4 :|
        V:2 name="Bass" clef=bass

        |: C,2 G,2 E,2 G,2 | G,,2 D,2 G,2 D,2 | C,2 G,2 E,2 G,2 | G,,2 D,2 G,2 D,2 |
        |  A,,2 E,2 F,,2 C,2 | G,,2 G,,2 C,4 :|
        """)

        let parsed = try parseChunks(data)
        XCTAssertEqual(parsed.format, 1)
        XCTAssertEqual(parsed.trackCount, 3)
        XCTAssertEqual(parsed.tracks.count, 3)

        let leadTrack = [UInt8](parsed.tracks[1])
        let bassTrack = [UInt8](parsed.tracks[2])

        XCTAssertTrue(leadTrack.starts(with: [0x00, 0xC0, 0x00, 0x00, 0x90]))
        XCTAssertTrue(bassTrack.starts(with: [0x00, 0xC1, 0x00, 0x00, 0x91]))
        XCTAssertGreaterThan(countNoteOnEvents(in: leadTrack), 0)
        XCTAssertGreaterThan(countNoteOnEvents(in: bassTrack), 0)
    }
}

private func readUInt16(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 |
    UInt32(data[offset + 1]) << 16 |
    UInt32(data[offset + 2]) << 8 |
    UInt32(data[offset + 3])
}

private extension Array where Element == UInt8 {
    func contains(contentsOf needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) {
            if Array(self[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}

private func countNoteOnEvents(in bytes: [UInt8]) -> Int {
    var position = 0
    var runningStatus: UInt8?
    var noteOnCount = 0

    while position < bytes.count {
        let (deltaLength, nextPosition) = readVarLen(bytes, startingAt: position)
        _ = deltaLength
        position = nextPosition
        guard position < bytes.count else { break }

        var status = bytes[position]
        if status < 0x80 {
            guard let runningStatus else { break }
            status = runningStatus
        } else {
            position += 1
            if status < 0xF0 {
                runningStatus = status
            } else {
                runningStatus = nil
            }
        }

        switch status {
        case 0x80...0x8F, 0xA0...0xAF, 0xB0...0xBF, 0xE0...0xEF:
            position += 2
        case 0x90...0x9F:
            guard position + 1 < bytes.count else { return noteOnCount }
            let velocity = bytes[position + 1]
            if velocity > 0 {
                noteOnCount += 1
            }
            position += 2
        case 0xC0...0xCF, 0xD0...0xDF:
            position += 1
        case 0xFF:
            guard position < bytes.count else { return noteOnCount }
            position += 1
            let (_, lengthStart) = readVarLen(bytes, startingAt: position)
            let (payloadLength, payloadStart) = readVarLen(bytes, startingAt: position)
            position = payloadStart + payloadLength
        case 0xF0, 0xF7:
            let (payloadLength, payloadStart) = readVarLen(bytes, startingAt: position)
            position = payloadStart + payloadLength
        default:
            return noteOnCount
        }
    }

    return noteOnCount
}

private func readVarLen(_ bytes: [UInt8], startingAt start: Int) -> (Int, Int) {
    var value = 0
    var position = start

    while position < bytes.count {
        let byte = bytes[position]
        position += 1
        value = (value << 7) | Int(byte & 0x7F)
        if byte & 0x80 == 0 {
            break
        }
    }

    return (value, position)
}
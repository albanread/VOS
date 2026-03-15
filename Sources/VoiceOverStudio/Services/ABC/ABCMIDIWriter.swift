import Foundation

struct ABCMIDIWriter {
    var ticksPerQuarter: Int

    init(ticksPerQuarter: Int = 480) {
        self.ticksPerQuarter = ticksPerQuarter
    }

    func write(tracks: [ABCMIDITrack]) -> Data {
        var data = Data()
        writeHeader(numTracks: tracks.count, into: &data)
        for track in tracks {
            writeTrack(track, into: &data)
        }
        return data
    }

    private func writeHeader(numTracks: Int, into data: inout Data) {
        data.appendASCII("MThd")
        data.appendUInt32(6)
        data.appendUInt16(1)
        data.appendUInt16(UInt16(clamping: numTracks))
        data.appendUInt16(UInt16(clamping: ticksPerQuarter))
    }

    private func writeTrack(_ track: ABCMIDITrack, into data: inout Data) {
        var trackData = Data()
        var lastTime = 0.0
        let sortedEvents = track.events.sorted {
            if $0.timestamp == $1.timestamp {
                return writerEventPriority($0.type) < writerEventPriority($1.type)
            }
            return $0.timestamp < $1.timestamp
        }

        for event in sortedEvents {
            let deltaTicks = max(0, Int((event.timestamp - lastTime) * Double(ticksPerQuarter)))
            trackData.appendVarLen(UInt32(deltaTicks))
            writeEvent(event, into: &trackData)
            lastTime = event.timestamp
        }

        data.appendASCII("MTrk")
        data.appendUInt32(UInt32(trackData.count))
        data.append(trackData)
    }

    private func writeEvent(_ event: ABCMIDIEvent, into data: inout Data) {
        switch event.type {
        case .noteOn:
            data.appendByte(0x90 | UInt8(event.channel & 0x0F))
            data.appendByte(UInt8(clamping: event.data1))
            data.appendByte(UInt8(clamping: event.data2))
        case .noteOff:
            data.appendByte(0x80 | UInt8(event.channel & 0x0F))
            data.appendByte(UInt8(clamping: event.data1))
            data.appendByte(UInt8(clamping: event.data2))
        case .programChange:
            data.appendByte(0xC0 | UInt8(event.channel & 0x0F))
            data.appendByte(UInt8(clamping: event.data1))
        case .controlChange:
            data.appendByte(0xB0 | UInt8(event.channel & 0x0F))
            data.appendByte(UInt8(clamping: event.data1))
            data.appendByte(UInt8(clamping: event.data2))
        case .metaTempo:
            data.appendMetaEvent(type: 0x51, payload: event.metaData)
        case .metaTimeSignature:
            data.appendMetaEvent(type: 0x58, payload: event.metaData)
        case .metaKeySignature:
            data.appendMetaEvent(type: 0x59, payload: event.metaData)
        case .metaText:
            data.appendMetaEvent(type: 0x01, payload: event.metaData)
        case .metaEndOfTrack:
            data.appendMetaEvent(type: 0x2F, payload: [])
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendByte(_ value: UInt8) {
        append(contentsOf: [value])
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    mutating func appendVarLen(_ value: UInt32) {
        var buffer = [UInt8](repeating: 0, count: 4)
        var index = 0
        var remainder = value
        buffer[index] = UInt8(remainder & 0x7F)
        remainder >>= 7

        while remainder > 0 {
            index += 1
            buffer[index] = UInt8((remainder & 0x7F) | 0x80)
            remainder >>= 7
        }

        while true {
            appendByte(buffer[index])
            if index == 0 { break }
            index -= 1
        }
    }

    mutating func appendMetaEvent(type: UInt8, payload: [UInt8]) {
        appendByte(0xFF)
        appendByte(type)
        appendVarLen(UInt32(payload.count))
        append(contentsOf: payload)
    }
}

private func writerEventPriority(_ type: ABCMIDIEventType) -> Int {
    switch type {
    case .programChange: return 0
    case .metaTempo, .metaTimeSignature, .metaKeySignature, .metaText: return 1
    case .noteOff: return 2
    case .noteOn: return 3
    case .controlChange: return 4
    case .metaEndOfTrack: return 5
    }
}
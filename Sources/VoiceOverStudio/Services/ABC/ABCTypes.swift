import Foundation

struct ABCFraction: Equatable {
    var num: Int
    var denom: Int

    init(_ num: Int, _ denom: Int) {
        let safeDenom = denom == 0 ? 1 : denom
        let sign = safeDenom < 0 ? -1 : 1
        let normalizedNum = num * sign
        let normalizedDenom = abs(safeDenom)
        let divisor = Self.gcd(abs(normalizedNum), normalizedDenom)
        self.num = divisor == 0 ? normalizedNum : normalizedNum / divisor
        self.denom = divisor == 0 ? normalizedDenom : normalizedDenom / divisor
    }

    func toDouble() -> Double {
        Double(num) / Double(denom)
    }

    func mul(_ other: ABCFraction) -> ABCFraction {
        ABCFraction(num * other.num, denom * other.denom)
    }

    func add(_ other: ABCFraction) -> ABCFraction {
        ABCFraction(num * other.denom + other.num * denom, denom * other.denom)
    }

    func mulInt(_ multiplier: Int) -> ABCFraction {
        ABCFraction(num * multiplier, denom)
    }

    func divInt(_ divisor: Int) -> ABCFraction {
        ABCFraction(num, denom * divisor)
    }

    private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}

struct ABCTempo: Equatable {
    var bpm: Int
}

struct ABCTimeSig: Equatable {
    var num: Int
    var denom: Int
}

struct ABCKeySig: Equatable {
    var sharps: Int
    var isMajor: Bool
}

struct ABCVoiceContext: Equatable {
    var id: Int
    var name: String
    var key: ABCKeySig
    var timeSig: ABCTimeSig
    var unitLen: ABCFraction
    var transpose: Int
    var octaveShift: Int
    var instrument: Int
    var channel: Int
    var velocity: Int
    var percussion: Bool
}

struct ABCNote: Equatable {
    var pitch: Character
    var accidental: Int
    var octave: Int
    var duration: ABCFraction
    var midiNote: Int
    var velocity: Int
    var isTied: Bool
}

struct ABCRest: Equatable {
    var duration: ABCFraction
}

struct ABCChord: Equatable {
    var notes: [ABCNote]
    var duration: ABCFraction
}

struct ABCGuitarChord: Equatable {
    var symbol: String
    var rootNote: Int
    var chordType: String
    var duration: ABCFraction
}

enum ABCBarLineType: Equatable {
    case bar1
    case doubleBar
    case repBar
    case barRep
    case doubleRep
}

struct ABCBarLine: Equatable {
    var barType: ABCBarLineType
}

struct ABCVoiceChange: Equatable {
    var voiceNumber: Int
    var voiceName: String
}

enum ABCFeatureData: Equatable {
    case note(ABCNote)
    case rest(ABCRest)
    case chord(ABCChord)
    case gchord(ABCGuitarChord)
    case bar(ABCBarLine)
    case tempo(ABCTempo)
    case time(ABCTimeSig)
    case key(ABCKeySig)
    case voice(ABCVoiceChange)
}

struct ABCFeature: Equatable {
    var voiceID: Int
    var timestamp: Double
    var lineNumber: Int
    var data: ABCFeatureData
}

struct ABCTune {
    var title: String = ""
    var history: String = ""
    var composer: String = ""
    var origin: String = ""
    var rhythm: String = ""
    var notes: String = ""
    var words: String = ""
    var alignedWords: String = ""

    var defaultKey = ABCKeySig(sharps: 0, isMajor: true)
    var defaultTimeSig = ABCTimeSig(num: 4, denom: 4)
    var defaultUnit = ABCFraction(1, 8)
    var defaultTempo = ABCTempo(bpm: 120)
    var defaultInstrument: Int = 0
    var defaultChannel: Int = -1
    var defaultPercussion: Bool = false

    var voices: [Int: ABCVoiceContext] = [:]
    var features: [ABCFeature] = []
}
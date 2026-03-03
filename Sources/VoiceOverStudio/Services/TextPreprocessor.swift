//
//  TextPreprocessor.swift
//  VoiceOverStudio
//

import Foundation

/// Deterministic, regex-driven text cleaner for TTS.
/// Applied when the user taps "Improve" to expand symbols, dates, and numbers
/// into spoken-friendly forms before sending to the TTS engine.
enum TextPreprocessor {
    static func preprocess(_ input: String) -> String {
        var text = input
        text = stripSimpleMarkdown(text)
        text = expandDates(text)
        text = expandTimes(text)
        text = expandCurrencyAndPercent(text)
        text = expandSymbols(text)
        text = expandAbbreviations(text)
        text = expandFractions(text)
        text = spellOutStandaloneNumbers(text)
        text = collapseWhitespace(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Steps

    private static func stripSimpleMarkdown(_ text: String) -> String {
        replace(text, pattern: "[*_#]+", with: "")
    }

    private static func expandSymbols(_ text: String) -> String {
        var result = text
        result = replace(result, pattern: "(?<=\\w)\\s*&\\s*(?=\\w)", with: " and ")
        result = replace(result, pattern: "(?<=\\d)\\s*%", with: " percent")
        result = replace(result, pattern: "@", with: " at ")
        // Turn isolated slash into the word to avoid "slash" being read literally.
        result = replace(result, pattern: "(?<=\\w)/(?!\\s)", with: " slash ")
        return result
    }

    private static func expandCurrencyAndPercent(_ text: String) -> String {
        var result = text
        result = replace(result, pattern: "\\$\\s*([0-9.,]+)", with: "$1 dollars")
        result = replace(result, pattern: "£\\s*([0-9.,]+)", with: "$1 pounds")
        result = replace(result, pattern: "€\\s*([0-9.,]+)", with: "$1 euros")
        return result
    }

    private static func expandAbbreviations(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("\\bDr\\.(?=\\s+[A-Z])", "Doctor"),
            ("\\bMr\\.(?=\\s+[A-Z])", "Mister"),
            ("\\bMrs\\.(?=\\s+[A-Z])", "Missus"),
            ("\\bMs\\.(?=\\s+[A-Z])", "Miss"),
            ("\\bProf\\.(?=\\s+[A-Z])", "Professor"),
            ("\\bCapt\\.(?=\\s+[A-Z])", "Captain"),
            ("\\bGov\\.(?=\\s+[A-Z])", "Governor"),
            ("\\bSen\\.(?=\\s+[A-Z])", "Senator"),
            ("\\bvs\\.?\\b", "versus"),
            ("\\be\\.g\\.", "for example"),
            ("\\bi\\.e\\.", "that is"),
            ("\\betc\\.", "et cetera")
        ]

        var result = text
        for (pattern, replacement) in replacements {
            result = replace(result, pattern: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private static func expandFractions(_ text: String) -> String {
        var result = text
        let commonFractions: [(String, String)] = [
            ("\\b1/2\\b", "one half"),
            ("\\b1/3\\b", "one third"),
            ("\\b2/3\\b", "two thirds"),
            ("\\b3/4\\b", "three quarters")
        ]
        for (pattern, replacement) in commonFractions {
            result = replace(result, pattern: pattern, with: replacement)
        }
        return result
    }

    private static func expandDates(_ text: String) -> String {
        // Matches MM/DD/YYYY or M/D/YY and turns it into a spoken Month Day Year string.
        let pattern = "(?<!\\w)(\\d{1,2})/(\\d{1,2})/(\\d{2,4})(?!\\w)"
        return replaceWithEvaluator(text, pattern: pattern) { match in
            guard match.numberOfRanges == 4,
                  let mRange = Range(match.range(at: 1), in: text),
                  let dRange = Range(match.range(at: 2), in: text),
                  let yRange = Range(match.range(at: 3), in: text) else { return nil }

            let month = Int(text[mRange]) ?? 0
            let day = Int(text[dRange]) ?? 0
            var year = Int(text[yRange]) ?? 0
            if year < 100 { year += 2000 }

            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            let calendar = Calendar(identifier: .gregorian)
            guard let date = calendar.date(from: comps) else { return nil }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM d yyyy"
            var spoken = formatter.string(from: date)
            spoken = spellOutStandaloneNumbers(spoken)
            return spoken
        }
    }

    private static func expandTimes(_ text: String) -> String {
        // Converts 3:30 PM -> three thirty P M ; 14:05 -> fourteen oh five
        let pattern = "(?<!\\w)(\\d{1,2}):(\\d{2})(?:\\s*([aApP][mM]))?(?!\\d)"
        return replaceWithEvaluator(text, pattern: pattern) { match in
            guard match.numberOfRanges >= 3,
                  let hRange = Range(match.range(at: 1), in: text),
                  let mRange = Range(match.range(at: 2), in: text) else { return nil }

            let hourVal = Int(text[hRange]) ?? 0
            let minuteVal = Int(text[mRange]) ?? 0
            let ampmRange = match.range(at: 3)
            var ampmString = ""
            if ampmRange.location != NSNotFound, let range = Range(ampmRange, in: text) {
                let raw = text[range].lowercased()
                ampmString = raw.contains("a") ? " A M" : " P M"
            }

            let hourSpoken = spellOut(hourVal)
            let minuteSpoken: String
            if minuteVal == 0 {
                minuteSpoken = "o'clock"
            } else if minuteVal < 10 {
                minuteSpoken = "oh " + spellOut(minuteVal)
            } else {
                minuteSpoken = spellOut(minuteVal)
            }

            return "\(hourSpoken) \(minuteSpoken)\(ampmString)"
        }
    }

    private static func spellOutStandaloneNumbers(_ text: String) -> String {
        // Spell out integers like 123 or 1,234. Avoid decimals here (handled elsewhere).
        let pattern = "(?<![\\w.])(\\d{1,3}(?:,\\d{3})*|\\d+)(?![\\w.])"
        return replaceWithEvaluator(text, pattern: pattern) { match in
            guard match.numberOfRanges == 2, let r = Range(match.range(at: 1), in: text) else { return nil }
            let token = text[r].replacingOccurrences(of: ",", with: "")
            if token.contains(".") { return nil }
            guard let value = Int(token) else { return nil }
            return spellOut(value)
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        replace(text, pattern: "\\s{2,}", with: " ")
    }

    // MARK: - Helpers

    private static func replace(_ text: String, pattern: String, with template: String, options: String.CompareOptions = [.regularExpression]) -> String {
        return text.replacingOccurrences(of: pattern, with: template, options: options)
    }

    private static func replaceWithEvaluator(_ text: String, pattern: String, evaluator: (NSTextCheckingResult) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        let matches = regex.matches(in: text, options: [], range: nsRange).reversed()
        for match in matches {
            guard let replacement = evaluator(match) else { continue }
            if let range = Range(match.range(at: 0), in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func spellOut(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }
}
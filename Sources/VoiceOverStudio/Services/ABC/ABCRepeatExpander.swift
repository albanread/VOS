import Foundation

enum ABCRepeatExpander {
    static func expandABCRepeats(_ abcContent: String) -> String {
        var output: [String] = []
        var inHeader = true
        var currentVoiceSection: [String] = []
        var inVoiceSection = false

        let lines = abcContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in lines {
            if inHeader {
                output.append(line)
                if line.hasPrefix("K:") {
                    inHeader = false
                }
                continue
            }

            if line.hasPrefix("V:") {
                flushVoiceSection(currentVoiceSection, into: &output)
                currentVoiceSection.removeAll(keepingCapacity: true)
                output.append(line)
                continue
            }

            if line.hasPrefix("%%") {
                flushVoiceSection(currentVoiceSection, into: &output)
                currentVoiceSection.removeAll(keepingCapacity: true)
                inVoiceSection = false
                output.append(line)
                continue
            }

            if line.hasPrefix("[V:") {
                flushVoiceSection(currentVoiceSection, into: &output)
                currentVoiceSection.removeAll(keepingCapacity: true)
                output.append(line)
                inVoiceSection = true
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushVoiceSection(currentVoiceSection, into: &output)
                currentVoiceSection.removeAll(keepingCapacity: true)
                inVoiceSection = false
                output.append(line)
                continue
            }

            if inVoiceSection {
                currentVoiceSection.append(line)
            } else {
                inVoiceSection = true
                currentVoiceSection.append(line)
            }
        }

        flushVoiceSection(currentVoiceSection, into: &output)
        return output.joined(separator: "\n")
    }

    private static func flushVoiceSection(_ section: [String], into output: inout [String]) {
        guard !section.isEmpty else { return }
        output.append(contentsOf: expandVoiceSectionRepeats(section))
    }

    private static func expandVoiceSectionRepeats(_ lines: [String]) -> [String] {
        var output: [String] = []
        var repeatBuffer: [String] = []
        var inRepeat = false

        for line in lines {
            if let start = line.range(of: "|:") {
                inRepeat = true
                if line.contains(":|") {
                    output.append(expandLineRepeats(line))
                    inRepeat = false
                    continue
                }

                let prefix = String(line[..<start.lowerBound])
                let suffix = String(line[start.upperBound...])
                repeatBuffer.append(prefix + "|" + suffix)
                continue
            }

            if inRepeat {
                if let end = line.range(of: ":|") {
                    let prefix = String(line[..<end.lowerBound])
                    let suffix = String(line[end.upperBound...])
                    repeatBuffer.append(prefix + "|" + suffix)

                    output.append(contentsOf: repeatBuffer)
                    output.append(contentsOf: repeatBuffer)
                    repeatBuffer.removeAll(keepingCapacity: true)
                    inRepeat = false
                    continue
                }

                repeatBuffer.append(line)
                continue
            }

            output.append(line)
        }

        if !repeatBuffer.isEmpty {
            output.append(contentsOf: repeatBuffer)
        }

        return output
    }

    private static func expandLineRepeats(_ line: String) -> String {
        var result = ""
        var cursor = line.startIndex

        while cursor < line.endIndex,
              let start = line[cursor...].range(of: "|:"),
              let end = line[start.upperBound...].range(of: ":|") {
            result += String(line[cursor..<start.lowerBound])
            let content = String(line[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            result += content + " " + content
            cursor = end.upperBound
        }

        if cursor < line.endIndex {
            result += String(line[cursor...])
        }

        return result
    }
}
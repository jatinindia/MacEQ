import Foundation

/// A parsed Equalizer APO configuration: the native preset format of MacEQ,
/// directly compatible with AutoEQ / Peace / REW / Wavelet exports.
public struct EQPreset: Equatable {
    public var preampDB: Double
    public var filters: [FilterSpec]

    public init(preampDB: Double, filters: [FilterSpec]) {
        self.preampDB = preampDB
        self.filters = filters
    }
}

/// Parse failure with enough context to point the user at the broken line.
public struct APOParseError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String { "line \(line): \(message)" }
}

/// A line the importer left out because it doesn't affect MacEQ's sound, kept
/// so the user can be told what was skipped.
public struct APOSkippedLine: Equatable {
    public let line: Int
    public let text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

public struct APOParseResult: Equatable {
    public let preset: EQPreset
    public let skippedLines: [APOSkippedLine]

    public init(preset: EQPreset, skippedLines: [APOSkippedLine]) {
        self.preset = preset
        self.skippedLines = skippedLines
    }
}

/// One sentence telling the user what an import left out, or nil if nothing.
public func describeSkippedLines(_ lines: [APOSkippedLine]) -> String? {
    guard !lines.isEmpty else { return nil }
    let shown = lines.prefix(3).map { "line \($0.line) “\($0.text)”" }
    let remainder = lines.count - shown.count
    let list = shown.joined(separator: ", ") + (remainder > 0 ? ", and \(remainder) more" : "")
    return "Skipped \(lines.count) \(lines.count == 1 ? "line" : "lines") MacEQ doesn't use: \(list)."
}

/// Equalizer APO commands MacEQ can't carry out and whose absence changes the
/// sound, so importing the rest would give a preset that sounds different
/// from the file. (GraphicEQ and Channel get their own handling below.)
private let unsupportedCommands: Set<String> = [
    "delay", "copy", "include", "convolution", "eval",
    "if", "elseif", "else", "endif", "loudnesscorrection", "vstplugin",
]

/// Parses APO config.txt text (AutoEQ, REW, Peace and hand-written exports).
///
/// Nothing is dropped silently:
/// - Preamp and Filter lines are applied; REW's empty "None" filter slots are
///   placeholders and are passed over.
/// - Commands that would change the sound but that MacEQ can't carry out
///   (GraphicEQ, Delay, Include, per-channel Channel sections, ...) throw,
///   naming the line.
/// - Anything else (Device:, Stage:, REW's header lines, unknown text) doesn't
///   affect the sound on a Mac; it is skipped and returned in `skippedLines`
///   so the caller can say so.
///
/// Fields may be separated by any whitespace. Decimal commas (European
/// exports) are accepted alongside decimal points.
public func parseAPOConfig(_ text: String) throws -> APOParseResult {
    var preampDB = 0.0
    var filters: [FilterSpec] = []
    var skippedLines: [APOSkippedLine] = []

    for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
        let lineNumber = index + 1
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        guard let colon = line.firstIndex(of: ":") else {
            skippedLines.append(APOSkippedLine(line: lineNumber, text: line))
            continue
        }

        let commandName = line[..<colon].trimmingCharacters(in: .whitespaces)
        let command = commandName.lowercased()
        let arguments = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

        if command == "preamp" {
            preampDB += try parseNumber(
                arguments.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces),
                line: lineNumber, what: "preamp gain"
            )
        } else if command.hasPrefix("filter") {
            if let filter = try parseFilterLine(arguments, line: lineNumber) {
                filters.append(filter)
            }
        } else if command == "channel" {
            try requireBothChannels(arguments, line: lineNumber)
        } else if command == "graphiceq" {
            throw APOParseError(
                line: lineNumber,
                message: "GraphicEQ isn't supported, and leaving it out would change how this preset sounds. "
                    + "For AutoEQ, import the ParametricEQ.txt file instead."
            )
        } else if unsupportedCommands.contains(command) {
            throw APOParseError(
                line: lineNumber,
                message: "\(commandName) isn't supported, and leaving it out would change how this preset sounds"
            )
        } else {
            skippedLines.append(APOSkippedLine(line: lineNumber, text: line))
        }
    }
    return APOParseResult(preset: EQPreset(preampDB: preampDB, filters: filters), skippedLines: skippedLines)
}

/// MacEQ runs one filter chain on both channels. A Channel: selection covering
/// both left and right (all, L R, 1 2; other channels don't exist on a stereo
/// output) is exactly that. Anything narrower means per-channel filters,
/// which would otherwise land on both ears.
private func requireBothChannels(_ arguments: String, line: Int) throws {
    let names = Set(arguments.split(whereSeparator: \.isWhitespace).map { $0.uppercased() })
    let coversLeft = names.contains("L") || names.contains("1")
    let coversRight = names.contains("R") || names.contains("2")
    guard names.contains("ALL") || (coversLeft && coversRight) else {
        throw APOParseError(
            line: line,
            message: "Channel: \(arguments) applies filters to only some channels, but MacEQ applies "
                + "one filter chain to both channels, so this preset can't be imported as intended"
        )
    }
}

/// Parses one number. Double() also accepts "nan" and "inf", which would pass
/// straight through to the audio as NaN, so only finite values count.
private func parseNumber(_ token: String, line: Int, what: String) throws -> Double {
    guard let value = Double(token.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
        throw APOParseError(line: line, message: "expected a number for \(what), got '\(token)'")
    }
    return value
}

/// Parses the part after "Filter n:", e.g. "ON PK Fc 105 Hz Gain -4.0 dB Q 0.90".
/// Returns nil for REW's unused slots ("ON None"), which define no filter.
private func parseFilterLine(_ arguments: String, line: Int) throws -> FilterSpec? {
    var tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !tokens.isEmpty else {
        throw APOParseError(line: line, message: "empty filter definition")
    }

    var isEnabled = true
    if tokens[0].uppercased() == "ON" || tokens[0].uppercased() == "OFF" {
        isEnabled = tokens[0].uppercased() == "ON"
        tokens.removeFirst()
    }
    guard !tokens.isEmpty else {
        throw APOParseError(line: line, message: "missing filter type")
    }

    let typeCode = tokens.removeFirst().uppercased()
    guard typeCode != "NONE" else { return nil }
    let type: FilterType
    if let known = FilterType(rawValue: typeCode) {
        type = known
    } else if typeCode == "PEQ" {
        type = .peaking
    } else {
        throw APOParseError(line: line, message: "unsupported filter type '\(typeCode)'")
    }

    var frequency: Double?
    var gainDB = 0.0
    var q: Double?
    var bandwidthOctaves: Double?

    var index = 0
    while index < tokens.count {
        let keyword = tokens[index].lowercased()
        switch keyword {
        case "fc":
            frequency = try parseNumber(try value(after: index, in: tokens, line: line), line: line, what: "Fc")
            index += 2
            if index < tokens.count, tokens[index].lowercased() == "hz" { index += 1 }
        case "gain":
            gainDB = try parseNumber(try value(after: index, in: tokens, line: line), line: line, what: "gain")
            index += 2
            if index < tokens.count, tokens[index].lowercased() == "db" { index += 1 }
        case "q":
            q = try parseNumber(try value(after: index, in: tokens, line: line), line: line, what: "Q")
            index += 2
        case "bw":
            // "BW Oct <n>": bandwidth in octaves.
            var valueIndex = index + 1
            if valueIndex < tokens.count, tokens[valueIndex].lowercased() == "oct" { valueIndex += 1 }
            guard valueIndex < tokens.count else {
                throw APOParseError(line: line, message: "BW keyword without a value")
            }
            let octaves = try parseNumber(tokens[valueIndex], line: line, what: "bandwidth")
            guard octaves > 0 else {
                throw APOParseError(line: line, message: "bandwidth must be a positive number of octaves, got \(octaves)")
            }
            bandwidthOctaves = octaves
            index = valueIndex + 1
        default:
            index += 1
        }
    }

    guard let frequency else {
        throw APOParseError(line: line, message: "filter has no Fc")
    }
    if q == nil, let bandwidthOctaves {
        // RBJ bandwidth-to-Q (midband approximation): 1/Q = 2·sinh(ln2/2 · N)
        q = 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bandwidthOctaves))
    }
    let spec = FilterSpec(
        type: type,
        isEnabled: isEnabled,
        frequency: frequency,
        gainDB: gainDB,
        q: q ?? butterworthQ
    )
    do {
        try validateFilter(spec)
    } catch let error as FilterSpecError {
        throw APOParseError(line: line, message: error.description)
    }
    return spec
}

private func value(after index: Int, in tokens: [String], line: Int) throws -> String {
    guard index + 1 < tokens.count else {
        throw APOParseError(line: line, message: "keyword '\(tokens[index])' without a value")
    }
    return tokens[index + 1]
}

/// The graphic EQ as an APO preset: one peaking filter per band, the same
/// filter the audio path runs for it. Bands at 0 dB are kept so the band
/// layout survives the trip to another app and back.
public func graphicEQPreset(frequencies: [Double], gains: [Double], q: Double, preampDB: Double) -> EQPreset {
    precondition(
        frequencies.count == gains.count,
        "graphicEQPreset needs one gain per band, got \(frequencies.count) bands and \(gains.count) gains"
    )
    let filters = zip(frequencies, gains).map { frequency, gain in
        FilterSpec(type: .peaking, isEnabled: true, frequency: frequency, gainDB: gain, q: q)
    }
    return EQPreset(preampDB: preampDB, filters: filters)
}

/// Serializes a preset back to APO config.txt text (AutoEQ-style formatting).
public func serializeAPOConfig(_ preset: EQPreset) -> String {
    var lines = [String(format: "Preamp: %.1f dB", preset.preampDB)]
    for (index, filter) in preset.filters.enumerated() {
        var parts = [
            "Filter \(index + 1):",
            filter.isEnabled ? "ON" : "OFF",
            filter.type.rawValue,
            "Fc",
            formatFrequency(filter.frequency),
            "Hz",
        ]
        if filter.type.usesGain {
            parts.append(contentsOf: ["Gain", String(format: "%.1f", filter.gainDB), "dB"])
        }
        if filter.type.usesQ {
            parts.append(contentsOf: ["Q", String(format: "%.2f", filter.q)])
        }
        lines.append(parts.joined(separator: " "))
    }
    return lines.joined(separator: "\n") + "\n"
}

private func formatFrequency(_ frequency: Double) -> String {
    frequency == frequency.rounded()
        ? String(Int(frequency))
        : String(format: "%.1f", frequency)
}

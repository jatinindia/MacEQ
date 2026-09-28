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

/// Parses APO config.txt text. Unknown commands (Device:, Include:, ...) are
/// skipped for forward compatibility; malformed Preamp/Filter lines throw.
/// Decimal commas (European exports) are accepted alongside decimal points.
public func parseAPOConfig(_ text: String) throws -> EQPreset {
    var preampDB = 0.0
    var filters: [FilterSpec] = []

    for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
        let lineNumber = index + 1
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        guard let colon = line.firstIndex(of: ":") else { continue }

        let command = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let arguments = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

        if command == "preamp" {
            preampDB += try parseNumber(
                arguments.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces),
                line: lineNumber, what: "preamp gain"
            )
        } else if command.hasPrefix("filter") {
            filters.append(try parseFilterLine(arguments, line: lineNumber))
        }
        // Anything else (Device:, Channel:, Include:, GraphicEQ:, ...) is skipped.
    }
    return EQPreset(preampDB: preampDB, filters: filters)
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
private func parseFilterLine(_ arguments: String, line: Int) throws -> FilterSpec {
    var tokens = arguments.split(separator: " ").map(String.init)
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

import Foundation

enum UserFiles {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

    static var vocabulary: [String] { lines("Vocabulary.txt") }

    static var replacements: [(pattern: String, replacement: String)] {
        rules(explicit: lines("Replacements.txt"), vocabulary: vocabulary)
    }

    static func rules(explicit: [String], vocabulary: [String]) -> [(pattern: String, replacement: String)] {
        let fromExplicit = explicit.compactMap { line -> (String, String)? in
            let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? ("\\b\(NSRegularExpression.escapedPattern(for: parts[0]))\\b", NSRegularExpression.escapedTemplate(for: parts[1])) : nil
        }
        let fromVocabulary = vocabulary.map { word -> (String, String) in
            let parts = word.matches(of: /[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])/).map { NSRegularExpression.escapedPattern(for: String($0.output)) }
            return ("\\b\(parts.joined(separator: "\\s?"))\\b", NSRegularExpression.escapedTemplate(for: word))
        }
        return fromExplicit + fromVocabulary
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private static func lines(_ name: String) -> [String] {
        ((try? String(contentsOf: url(name), encoding: .utf8)) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

enum TextPolish {
    static func apply(_ text: String, rules: [(pattern: String, replacement: String)] = UserFiles.replacements) -> String {
        var out = text.replacingOccurrences(of: "(?i)\\b(uh|um)\\b,?\\s*", with: "", options: .regularExpression)
        for rule in rules {
            out = out.replacingOccurrences(of: "(?i)\(rule.pattern)", with: rule.replacement, options: .regularExpression)
        }
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

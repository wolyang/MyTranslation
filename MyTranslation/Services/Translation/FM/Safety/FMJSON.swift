// Services/Translation/FM/Safety/FMJSON.swift
import Foundation

enum FMJSON {
    static func extractJSONStringArray(from s: String) -> [String]? {
        guard let start = s.lastIndex(of: "["), let end = s.lastIndex(of: "]"), start < end else { return nil }
        let json = String(s[start...end])
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr
    }
    static func extractFirstJSON(from s: String) -> String? {
        if let (a, b) = findBalanced(in: s, open: "{", close: "}") { return String(s[a...b]) }
        if let (a, b) = findBalanced(in: s, open: "[", close: "]") { return String(s[a...b]) }
        return nil
    }
    private static func findBalanced(in s: String, open: Character, close: Character) -> (String.Index, String.Index)? {
        var depth = 0; var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == open { if depth == 0 { start = i }; depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0, let st = start { return (st, i) }
            }
            i = s.index(after: i)
        }
        return nil
    }
    static func encodeJSONStringArray(_ arr: [String]) throws -> String {
        let data = try JSONEncoder().encode(arr)
        return String(decoding: data, as: UTF8.self)
    }
    static func simpleKoreanPolish(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        if !t.isEmpty, "!.?！？。".contains(t.last!) == false { t.append(".") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func tailLine(from prompt: String) -> String {
        String(prompt.split(whereSeparator: \.isNewline).last ?? "")
    }
}

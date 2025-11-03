// File: SentinelEncoding.swift
import Foundation

private let sentinelEncodeRegex: NSRegularExpression = {
    let pattern = #"__ENT#(\d+)__"#
    return try! NSRegularExpression(pattern: pattern, options: [])
}()

private let sentinelDecodeRegex: NSRegularExpression = {
    let pattern = #"🟧ENT(\d+)🟧"#
    return try! NSRegularExpression(pattern: pattern, options: [])
}()

func encodeSentinels(_ text: String) -> String {
    guard text.isEmpty == false else { return text }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    let matches = sentinelEncodeRegex.matches(in: text, options: [], range: range)
    guard matches.isEmpty == false else { return text }

    let mutable = NSMutableString(string: text)
    for match in matches.reversed() {
        let digits = nsText.substring(with: match.range(at: 1))
        let replacement = "🟧ENT\(digits)🟧"
        mutable.replaceCharacters(in: match.range, with: replacement)
    }
    return mutable as String
}

func decodeSentinels(_ text: String) -> String {
    guard text.isEmpty == false else { return text }
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    let matches = sentinelDecodeRegex.matches(in: text, options: [], range: range)
    guard matches.isEmpty == false else { return text }

    let mutable = NSMutableString(string: text)
    for match in matches.reversed() {
        let digits = nsText.substring(with: match.range(at: 1))
        let replacement = "__ENT#\(digits)__"
        mutable.replaceCharacters(in: match.range, with: replacement)
    }
    return mutable as String
}

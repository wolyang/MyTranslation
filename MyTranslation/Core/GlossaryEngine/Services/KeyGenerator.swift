//
//  KeyGenerator.swift
//  MyTranslation
//
//  Created by sailor.m on 11/10/25.
//

import Foundation

struct KeyGenPolicy: Sendable { var sheetPrefixLen: Int = 4; var maxBaseLen: Int = 48; var allowUserProvidedKeys: Bool = false }

enum RefToken: Sendable { case termKey(String); case ref(sheet: String, target: String) }

@MainActor
final class KeyGenerator {
    private let policy: KeyGenPolicy
    private var cache: [String:String] = [:]
    private var occupied: Set<String> = []
    init(policy: KeyGenPolicy = .init()) { self.policy = policy }
    func keyFor(sheetName: String, explicitKey: String?, target: String) -> String {
        let sheetSlug = makeSheetSlug(sheetName)
        let targetSlug = makeTargetSlug(target)
        let cacheKey = "\(sheetSlug)|\(targetSlug)"
        if let k = cache[cacheKey] { occupied.insert(k); return k }
        let base = "\(sheetSlug):\(targetSlug)"
        let unique = uniquify(base)
        cache[cacheKey] = unique
        occupied.insert(unique)
        return unique
    }
    func reserve(_ key: String) { occupied.insert(key) }
    func resolveToken(_ raw: String) -> RefToken {
        if raw.hasPrefix("ref:") {
            let body = String(raw.dropFirst(4))
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { return .ref(sheet: String(parts[0]), target: String(parts[1])) }
        }
        return .termKey(raw)
    }
    func resolveTokens(_ raws: [String], fromSheet sheet: String) -> [String] {
        var out: [String] = []
        for r in raws {
            switch resolveToken(r) {
            case .termKey(let k): out.append(k)
            case .ref(let s, let t):
                let sheetName = s.isEmpty ? sheet : s
                out.append(keyFor(sheetName: sheetName, explicitKey: nil, target: t))
            }
        }
        return out
    }
    func makeSheetSlug(_ sheetName: String) -> String {
        let s = asciiSlug(sheetName).uppercased()
        let trimmed = s.replacingOccurrences(of: "_+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(trimmed.prefix(policy.sheetPrefixLen))
    }
    func makeTargetSlug(_ text: String) -> String {
        let a = (text.applyingTransform(.toLatin, reverse: false) ?? text).folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        let ascii = a.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        let normalized = ascii.replacingOccurrences(of: "_+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if normalized.isEmpty { return codepointSlug(text) }
        let upper = normalized.uppercased()
        if upper.count <= policy.maxBaseLen { return upper }
        let head = upper.prefix(policy.maxBaseLen - 7)
        let tail = shortHash(upper)
        return head + "_" + tail
    }
    private func asciiSlug(_ s: String) -> String {
        let latin = (s.applyingTransform(.toLatin, reverse: false) ?? s)
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US"))
        let up = latin.uppercased()
        return up.replacingOccurrences(of: "[^A-Z0-9]", with: "_", options: .regularExpression)
    }
    private func codepointSlug(_ s: String) -> String {
        let hex = s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: "_")
        return "U" + hex
    }
    private func shortHash(_ s: String) -> String {
        var hash: UInt32 = 0x811C9DC5
        for b in s.utf8 { hash ^= UInt32(b); hash &*= 16777619 }
        return String(format: "%06X", hash & 0xFFFFFF)
    }
    private func uniquify(_ base: String) -> String {
        if !occupied.contains(base) { return base }
        var i = 2
        while true {
            let k = "\(base)-\(i)"
            if !occupied.contains(k) { return k }
            i += 1
        }
    }
}

import Foundation

extension Glossary.SDModel.GlossaryUpserter {
    func mergeSet<T: Hashable>(_ a: [T], _ b: [T]) -> [T] {
        let set = Glossary.SDModel.LinkedHashSet<T>(a) + b
        return Array(set)
    }

    func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        Array(Glossary.SDModel.LinkedHashSet<T>(values))
    }

    func deduplicatedMap<Element, Key: Hashable>(_ items: [Element], key: KeyPath<Element, Key>) -> [Key: Element] {
        var out: [Key: Element] = [:]
        for item in items {
            let k = item[keyPath: key]
            if out[k] == nil { out[k] = item }
        }
        return out
    }

    func normalizedActivatorKeys(_ rawKeys: [String]?, termKey: String) -> [String] {
        let keys = rawKeys ?? []
        var filtered: [String] = []
        var set = Glossary.SDModel.LinkedHashSet<String>()

        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                filtered.append(key)
                continue
            }
            _ = set.insert(trimmed)
        }

        if !filtered.isEmpty {
            print("[Import][WARN] Ignored empty activator keys for term \(termKey): \(filtered)")
        }

        return Array(set)
    }
}

extension Glossary.SDModel {
    struct LinkedHashSet<Element: Hashable>: Sequence {
        private var order: [Element] = []
        private var set: Set<Element> = []
        init() {}
        init(_ seq: some Sequence<Element>) { for e in seq { _ = insert(e) } }
        @discardableResult mutating func insert(_ e: Element) -> Bool {
            if set.insert(e).inserted { order.append(e); return true } else { return false }
        }
        static func + (lhs: LinkedHashSet<Element>, rhs: some Sequence<Element>) -> LinkedHashSet<Element> {
            var out = lhs
            for e in rhs { _ = out.insert(e) }
            return out
        }
        func makeIterator() -> IndexingIterator<[Element]> { order.makeIterator() }
    }
}

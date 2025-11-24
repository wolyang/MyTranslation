import Foundation

/// Glossary 매칭용 Aho-Corasick 구현체.
final class AhoCorasick {
    struct Node { var next: [Character: Int] = [:]; var fail: Int = 0; var out: [Int] = [] }

    private var nodes: [Node] = [Node()]
    private var patterns: [String] = []

    init(patterns: [String]) { build(patterns) }
    convenience init(_ patterns: [String]) { self.init(patterns: patterns) }

    private func build(_ pats: [String]) {
        patterns = pats
        nodes = [Node()]

        for (pid, pat) in pats.enumerated() {
            var state = 0
            for ch in pat {
                if let next = nodes[state].next[ch] {
                    state = next
                } else {
                    nodes[state].next[ch] = nodes.count
                    nodes.append(Node())
                    state = nodes.count - 1
                }
            }
            nodes[state].out.append(pid)
        }

        var queue: [Int] = []
        for (_, to) in nodes[0].next {
            nodes[to].fail = 0
            queue.append(to)
        }

        var idx = 0
        while idx < queue.count {
            let v = queue[idx]
            idx += 1

            for (ch, to) in nodes[v].next {
                queue.append(to)
                var fail = nodes[v].fail
                while fail != 0 && nodes[fail].next[ch] == nil {
                    fail = nodes[fail].fail
                }
                nodes[to].fail = nodes[fail].next[ch] ?? 0
                nodes[to].out += nodes[nodes[to].fail].out
            }
        }
    }

    struct Hit { let start: Int; let end: Int; let pid: Int }

    func find(in text: String) -> [Hit] {
        var result: [Hit] = []
        var state = 0
        let chars = Array(text)

        for (i, ch) in chars.enumerated() {
            while state != 0 && nodes[state].next[ch] == nil {
                state = nodes[state].fail
            }
            state = nodes[state].next[ch] ?? 0

            guard nodes[state].out.isEmpty == false else { continue }
            for pid in nodes[state].out {
                let matchLength = patterns[pid].count
                result.append(Hit(start: i - matchLength + 1, end: i + 1, pid: pid))
            }
        }

        return result
    }
}

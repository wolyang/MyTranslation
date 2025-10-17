// Services/Translation/FM/PostEdit/FMPostEditor.swift
// Services/Translation/FM/PostEdit/FMPostEditor.swift
import Foundation

public final class FMPostEditor: PostEditor {
    private let fm: FMModelManaging
    public init(fm: FMModelManaging) { self.fm = fm }

    public func postEditBatch(texts: [String], style: TranslationStyle) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        let styleDirective: String = {
            switch style {
            case .colloquialKo: return "자연스러운 구어체 한국어"
            case .neutralDictionaryTone: return "사전식의 중립적이고 간결한 한국어"
            }
        }()

        let limiter = ConcurrencyLimiter(limit: 4)
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, line) in texts.enumerated() {
                group.addTask { [styleDirective] in
                    try await limiter.run {
                        // 프롬프트: 락 토큰 보존을 강하게 지시
                        let prompt = """
                        아래 한국어 문장을 \(styleDirective)로 자연스럽게 다듬어라.
                        의미는 유지하고, 락 토큰(⟪T1⟫, ⟪T2⟫, ...)은 문자 그대로 보존하라.
                        추가 설명이나 접두/접미 문구 없이 문장만 출력하라.
                        
                        문장:
                        \(line)
                        """
                        let out: String = try await self.fm.complete(prompt: prompt)
                        return (i, out.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }

            var box = Array(repeating: "", count: texts.count)
            for try await (i, s) in group { box[i] = s }
            return box
        }
    }
}

struct ConcurrencyLimiter {
    private let semaphore: AsyncSemaphore
    init(limit: Int) { semaphore = AsyncSemaphore(value: limit) }

    func run<T>(_ op: @Sendable () async throws -> T) async throws -> T {
        try await semaphore.withPermit {
            try await op()
        }
    }
}

public actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) { self.value = value }

    public func acquire() async {
        if value > 0 { value -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { value += 1 }
    }

    // ✅ acquire/release를 actor 내부에서 처리 (defer 안전)
    public func withPermit<T>(
        _ op: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }   // actor 격리 내부라 OK
        return try await op()
    }
}

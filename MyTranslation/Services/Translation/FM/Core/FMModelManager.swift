import Foundation
import FoundationModels

public protocol FMTextGenerator: Sendable {
    func complete(prompt: String) async throws -> String
    func generate<T: Generable>(prompt: String) async throws -> T
}

public protocol FMModelManaging: FMTextGenerator, Sendable {
    var isAvailable: Bool { get async }
    func prepareIfNeeded() async
}

/// 세션 1개 + 임계영역(게이트)로 동시 1요청 보장
public actor FMModelManager: FMModelManaging {
    private var session: LanguageModelSession?
    private var prepared = false
    private var available = false
    // 재진입 방지 (동시 respond 금지)
    private let gate = AsyncSemaphore(value: 1)

    public init() {}

    public var isAvailable: Bool {
        get async { available }
    }

    public func prepareIfNeeded() async {
        guard !prepared else { return }
        prepared = true
        do {
            let s = LanguageModelSession(
                model: .default,
                instructions: """
                - Korean post-editor & structured generator.
                - Keep meaning; improve fluency.
                - Output exactly in the requested format when asked.
                """
            )
            _ = try await s.respond(to: "ping")
            self.session = s
            self.available = true
        } catch {
            self.session = nil
            self.available = false
            // 로그만 남기고, 호출부에서 폴백 처리
            print("FM warmup failed: \(error)")
        }
    }

    public func complete(prompt: String) async throws -> String {
        await prepareIfNeeded()
        guard available, let s = session else { return prompt } // 폴백: 그대로 반환
        // actor 격리: respond는 직렬 실행
        return try await gate.withPermit {
            print("[FM-PE] prompt.len=\(prompt.count)")
            return try await s.respond(to: prompt).content
        }
    }
    
    
    public func generate<T: Generable>(prompt: String) async throws -> T {
        await prepareIfNeeded()
        guard available, let s = session else {
            throw NSError(domain: "FM", code: -100,
                                      userInfo: [NSLocalizedDescriptionKey: "Foundation Models unavailable"])
        }
        
        return try await gate.withPermit {
            try await s.respond(to: prompt, generating: T.self).content
        }
    }
}

// File: AFMTranslationService.swift
import Foundation
import Translation

final class AFMTranslationService: AFMClient {
    private weak var session: TranslationSession?
    private var prepared = false

    init() { }

    @MainActor
    func attach(session: TranslationSession) {
        self.session = session
        self.prepared = false
    }

    @MainActor
    func translateBatch(
        texts: [String],
        style: TranslationStyle,
        preserveFormatting: Bool
    ) async throws -> [String] {
        guard let session else {
            throw NSError(
                domain: "AFMTranslationService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TranslationSession not attached"]
            )
        }
        if prepared == false {
            do {
                try await session.prepareTranslation()
                prepared = true
            } catch {
                // 원인 파악 위한 로깅 강화
                print("AFM prepareTranslation failed:", (error as NSError).domain, (error as NSError).code, (error as NSError).localizedDescription)
                throw error
            }
        }
        
        var out: [String] = []
        out.reserveCapacity(texts.count)
        for (idx, text) in texts.enumerated() {
            let len = text.count
            do {
                let response = try await session.translate(text)
                out.append(response.targetText)
            } catch {
                // 내부 에러/언어 인식 실패 케이스 로그 강화
                let ns = error as NSError
                print("[AFM][ERR] idx=\(idx) len=\(len) domain=\(ns.domain) code=\(ns.code) msg=\(ns.localizedDescription)")
                throw error
            }
        }
        return out
    }
}

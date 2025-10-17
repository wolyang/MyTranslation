//
//  FMOrchestrator.swift

import Foundation

actor FMOrchestrator {
    private let postEditor: PostEditor
    private let comparer: ResultComparer?
    private let reranker: Reranker?

    init(postEditor: PostEditor,
         comparer: ResultComparer?, reranker: Reranker?) {
        self.postEditor = postEditor
        self.comparer = comparer
        self.reranker = reranker
    }

    func process(_ results: [TranslationResult], source: String, options: TranslationOptions) async -> [TranslationResult] {
        // 1) Post-Edit (옵션: postEditor가 Nop이면 실질 no-op)
        let postEditedTexts: [String]
        do {
            postEditedTexts = try await postEditor.postEditBatch(
                texts: results.map(\.text),
                style: options.style
            )
        } catch {
            print("post edit error: \(error)")
            postEditedTexts = results.map(\.text)
        }

        // 결과 치환
        var updated: [TranslationResult] = zip(results, postEditedTexts).map { (orig, edited) in
            TranslationResult(
                id: orig.id, segmentID: orig.segmentID,
                engine: orig.engine, text: edited,
                residualSourceRatio: orig.residualSourceRatio,
                createdAt: orig.createdAt
            )
        }

        if let comparer {
            do {
                if let picked = try await comparer.compare(updated, source: source) {
                    updated = updated.map { $0.segmentID == picked.segmentID ? picked : $0 }
                }
            } catch {
                print("compare error: \(error)")
            }
        }
        if let reranker{
            do {
                updated = try await reranker.rerank(updated, source: source)
            } catch {
                print("rerank error: \(error)")
            }
        }

        return updated
    }
}

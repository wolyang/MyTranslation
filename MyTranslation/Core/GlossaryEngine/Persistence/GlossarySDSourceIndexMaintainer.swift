//
//  GlossarySDSourceIndexMaintainer.swift
//  MyTranslation
//
//  Created by sailor.m on 11/11/25.
//

import Foundation
import SwiftData

extension Glossary.SDModel {
    @MainActor
    enum SourceIndexMaintainer {
        /// Term 하나의 인덱스를 통째로 재생성(기존 행 삭제 후 생성)
        static func rebuild(for term: SDTerm, in ctx: ModelContext) throws {
            try deleteAll(for: term, in: ctx)

            let key = term.key
            for s in term.sources {
                let text = s.text
                guard !text.isEmpty else { continue }
                let grams  = Glossary.Util.qgrams(text, n: min(2, max(1, text.count)))
                let script =  Glossary.Util.detectScriptKind(text)
                let len    =  Glossary.Util.lengthBucket(text.count)
                for g in grams {
                    let row = SDSourceIndex(qgram: g, script: script.rawValue, len: len, term: term)
                    ctx.insert(row)
                }
            }
        }

        /// 특정 Term의 모든 인덱스 삭제
        static func deleteAll(for term: SDTerm, in ctx: ModelContext) throws {
            let id = term.persistentModelID
            let pred = #Predicate<SDSourceIndex> { $0.term.persistentModelID == id }
            let rows = try ctx.fetch(FetchDescriptor<SDSourceIndex>(predicate: pred))
            for r in rows { ctx.delete(r) }
        }
    }

}

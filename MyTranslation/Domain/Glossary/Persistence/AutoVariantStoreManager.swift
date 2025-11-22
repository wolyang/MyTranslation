//
//  AutoVariantStoreManager.swift
//  MyTranslation
//
//  Created by sailor.m on 11/6/25.
//

import Foundation
import SwiftData

final class AutoVariantStoreManager {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// 단일 (source, target) 쌍을 추가하거나 count 갱신
    func upsert(source: String, target: String, count: Int = 1) throws {
        let descriptor = FetchDescriptor<AutoVariantRecord>(
            predicate: #Predicate { $0.source == source && $0.target == target }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.count = count
        } else {
            context.insert(AutoVariantRecord(source: source, target: target, count: count))
        }
        try context.save()
    }

    /// 특정 source의 모든 후보 중, count가 일정 이상인 target 문자열 배열 리턴
    func fetchTargets(for source: String, minimumCount: Int) throws -> [String] {
        let descriptor = FetchDescriptor<AutoVariantRecord>(
            predicate: #Predicate { $0.source == source && $0.count >= minimumCount }
        )
        let records = try context.fetch(descriptor)
        return records.map(\.target)
    }

    /// 특정 source의 모든 후보 삭제
    func deleteAll(for source: String) throws {
        let descriptor = FetchDescriptor<AutoVariantRecord>(
            predicate: #Predicate { $0.source == source }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }
}

//
//  GlossarySDUpsert.swift
//  MyTranslation
//
//  Created by sailor.m on 11/8/25.
//

import Foundation
import SwiftUI
import SwiftData

extension Glossary.SDModel {
    
    enum ImportMergePolicy { case keepExisting, overwrite }
    
    struct ImportDryRunReport: Sendable {
        struct Bucket: Sendable { let newCount: Int; let updateCount: Int; let deleteCount: Int }
        struct KeyCollision: Sendable, Hashable { let key: String; let count: Int }
        let terms: Bucket
        let patterns: Bucket
        let warnings: [String]
        let termKeyCollisions: [KeyCollision]
        let patternKeyCollisions: [KeyCollision]
    }
    
    struct ImportSyncPolicy: Sendable {
        var removeMissingTerms = true
        var removeMissingPatterns = true
        var termDeletionFilter: (@Sendable (String) -> Bool)? = nil
        var patternDeletionFilter: (@Sendable (String) -> Bool)? = nil
    }
    
    @MainActor
    final class GlossaryUpserter {
        private let context: ModelContext
        private let merge: ImportMergePolicy
        private let sync: ImportSyncPolicy
        init(context: ModelContext, merge: ImportMergePolicy, sync: ImportSyncPolicy = .init()) {
            self.context = context
            self.merge = merge
            self.sync = sync
        }
        
        func apply(bundle: JSBundle) throws -> ImportDryRunReport {
            let report = try dryRun(bundle: bundle)
            try upsertTerms(bundle.terms)
            try upsertPatterns(bundle.patterns)
            if sync.removeMissingTerms || sync.removeMissingPatterns {
                try deleteMissing(bundle: bundle)
                try cleanupOrphans()
            }
            try context.save()
            return report
        }
        
        // 결과 예상 시뮬레이션 함수
        func dryRun(bundle: JSBundle) throws -> ImportDryRunReport {
            let existingTerms = try context.fetch(FetchDescriptor<SDTerm>())
            let existingTermKeys = Set(existingTerms.map { $0.key })
            let existingPatternIds = try fetchAllKeys(SDPattern.self, key: \SDPattern.name)
            let incomingTermKeys = bundle.terms.map { $0.key }
            let incomingPatternIds = bundle.patterns.map { $0.name }
            let incomingTermKeySet = Set(incomingTermKeys)
            let incomingPatternIdSet = Set(incomingPatternIds)
            let tNew = incomingTermKeySet.subtracting(existingTermKeys).count
            let tUpd = incomingTermKeySet.intersection(existingTermKeys).count
            let tDel: Int
            if sync.removeMissingTerms {
                let candidates = existingTermKeys.subtracting(incomingTermKeySet)
                if let filter = sync.termDeletionFilter {
                    tDel = candidates.filter { filter($0) }.count
                } else {
                    tDel = candidates.count
                }
            } else {
                tDel = 0
            }
            let pNew = incomingPatternIdSet.subtracting(existingPatternIds).count
            let pUpd = incomingPatternIdSet.intersection(existingPatternIds).count
            let pDel: Int
            if sync.removeMissingPatterns {
                let candidates = existingPatternIds.subtracting(incomingPatternIdSet)
                if let filter = sync.patternDeletionFilter {
                    pDel = candidates.filter { filter($0) }.count
                } else {
                    pDel = candidates.count
                }
            } else {
                pDel = 0
            }
            func collisions(_ arr: [String]) -> [ImportDryRunReport.KeyCollision] {
                var freq: [String:Int] = [:]
                for k in arr { freq[k, default: 0] += 1 }
                return freq.filter { $0.value > 1 }.map { .init(key: $0.key, count: $0.value) }.sorted { $0.key < $1.key }
            }
            let termCollisions = collisions(incomingTermKeys)
            let patternCollisions = collisions(incomingPatternIds)
            var warns: [String] = []
            if !termCollisions.isEmpty { warns.append("Duplicate Term keys in import: \(termCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }
            if !patternCollisions.isEmpty { warns.append("Duplicate Pattern ids in import: \(patternCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }
            return ImportDryRunReport(
                terms: .init(newCount: tNew, updateCount: tUpd, deleteCount: tDel),
                patterns: .init(newCount: pNew, updateCount: pUpd, deleteCount: pDel),
                warnings: warns,
                termKeyCollisions: termCollisions,
                patternKeyCollisions: patternCollisions
            )
        }
        
        private func upsertTerms(_ items: [JSTerm]) throws {
            var map: [String: SDTerm] = [:]
            for t in try context.fetch(FetchDescriptor<SDTerm>()) { map[t.key] = t }

            // Phase 1: 모든 Term을 생성/업데이트하고, activatedBy 정보 수집
            var activationMap: [String: [String]] = [:]  // termKey → activatorKeys
            for src in items {
                let dst: SDTerm
                if let existing = map[src.key] {
                    try update(term: existing, with: src)
                    dst = existing
                } else {
                    let created = SDTerm(key: src.key, target: src.target)
                    try update(term: created, with: src)
                    context.insert(created)
                    map[src.key] = created
                    dst = created
                }
                try SourceIndexMaintainer.rebuild(for: dst, in: context)

                // activatedByKeys 정보 수집
                if let activatorKeys = src.activatedByKeys, !activatorKeys.isEmpty {
                    activationMap[src.key] = activatorKeys
                }
            }

            // Phase 2: 모든 Term이 존재하는 상태에서 activator 관계 설정
            try setupActivatorRelationships(activationMap: activationMap, termMap: map)
        }
        
        private func update(term dst: SDTerm, with src: JSTerm) throws {
            if merge == .overwrite {
                dst.target = src.target
                dst.isAppellation = src.isAppellation
                dst.preMask = src.preMask
            } else {
                if dst.target.isEmpty { dst.target = src.target }
            }
            dst.variants = mergeSet(dst.variants, src.variants)

            upsertSources(term: dst, with: src)

            try upsertComponents(term: dst, with: src)

            try ensureTags(dst, names: src.tags)
        }

        private func setupActivatorRelationships(activationMap: [String: [String]], termMap: [String: SDTerm]) throws {
            // 새로운 관계 설정 (activators만 수정하면 activates는 inverse에 의해 자동 관리됨)
            for (termKey, activatorKeys) in activationMap {
                guard let term = termMap[termKey] else { continue }

                // overwrite 모드일 때는 기존 관계를 먼저 정리
                if merge == .overwrite {
                    // 기존 activators를 모두 제거하고 새로 설정
                    let oldActivators = term.activators
                    for oldActivator in oldActivators {
                        if let idx = term.activators.firstIndex(where: { $0.key == oldActivator.key }) {
                            term.activators.remove(at: idx)
                        }
                    }
                }

                // 새 activator 추가
                for activatorKey in activatorKeys {
                    // 이미 관계가 설정되어 있으면 스킵
                    if term.activators.contains(where: { $0.key == activatorKey }) {
                        continue
                    }

                    // activatorKey에 해당하는 Term 찾기
                    let activator: SDTerm?
                    if let found = termMap[activatorKey] {
                        activator = found
                    } else {
                        // DB에서 조회
                        let pred = #Predicate<SDTerm> { $0.key == activatorKey }
                        var desc = FetchDescriptor<SDTerm>(predicate: pred)
                        desc.fetchLimit = 1
                        activator = try context.fetch(desc).first
                    }

                    guard let activator = activator else {
                        print("[Import][Warning] Activator Term not found: \(activatorKey) for term: \(termKey)")
                        continue
                    }

                    // activators에만 추가 (activates는 자동 관리됨)
                    term.activators.append(activator)
                }
            }
        }
        
        private func upsertSources(term dst: SDTerm, with src: JSTerm) {
            var existingByText: [String: SDSource] = [:]
            for s in dst.sources { existingByText[s.text] = s }
            for js in src.sources {
                if let s = existingByText[js.source] {
                    if merge == .overwrite {
                        s.prohibitStandalone = js.prohibitStandalone
                    }
                } else {
                    let s = SDSource(text: js.source, prohibitStandalone: js.prohibitStandalone, term: dst)
                    context.insert(s)
                    dst.sources.append(s)
                }
            }
        }
        
        private func upsertComponents(term dst: SDTerm, with src: JSTerm) throws {
            var existingCompKeys: [String: SDComponent] = [:]
            var seen: Set<String> = []
            for c in dst.components { existingCompKeys[key(of: c)] = c }
            for jc in src.components {
                let compKey = key(of: jc)
                seen.insert(compKey)
                let comp: SDComponent
                if let c = existingCompKeys[compKey] {
                    comp = c
                    if merge == .overwrite {
                        comp.srcTplIdx = jc.srcTplIdx
                        comp.tgtTplIdx = jc.tgtTplIdx
                    }
                } else {
                    comp = SDComponent(pattern: jc.pattern, role: jc.role, srcTplIdx: jc.srcTplIdx, tgtTplIdx: jc.tgtTplIdx, term: dst)
                    context.insert(comp)
                    dst.components.append(comp)
                }
                if let groups = jc.groups {
                    try ensureGroups(groups, for: comp, pattern: jc.pattern)
                }
            }
            for (key, old) in existingCompKeys where !seen.contains(key) {
                if let idx = dst.components.firstIndex(where: { $0 === old }) {
                    dst.components.remove(at: idx)
                }
                context.delete(old)
            }
        }
        
        private func upsertPatterns(_ items: [JSPattern]) throws {
            var patternMap: [String: SDPattern] = [:]
            for p in try context.fetch(FetchDescriptor<SDPattern>()) { patternMap[p.name] = p }
            var metaMap: [String: SDPatternMeta] = [:]
            for meta in try context.fetch(FetchDescriptor<SDPatternMeta>()) { metaMap[meta.name] = meta }
            for js in items {
                let dst = patternMap[js.name] ?? SDPattern(name: js.name)
                if let l = js.left {
                    dst.leftRole = l.role
                    dst.leftTagsAll = l.tagsAll ?? []
                    dst.leftTagsAny = l.tagsAny ?? []
                    dst.leftIncludeTerms = try fetchTerms(for: l.includeTermKeys)
                    dst.leftExcludeTerms = try fetchTerms(for: l.excludeTermKeys)
                } else {
                    dst.leftRole = nil
                    dst.leftTagsAll = []
                    dst.leftTagsAny = []
                    dst.leftIncludeTerms = []
                    dst.leftExcludeTerms = []
                }
                if let r = js.right {
                    dst.rightRole = r.role
                    dst.rightTagsAll = r.tagsAll ?? []
                    dst.rightTagsAny = r.tagsAny ?? []
                    dst.rightIncludeTerms = try fetchTerms(for: r.includeTermKeys)
                    dst.rightExcludeTerms = try fetchTerms(for: r.excludeTermKeys)
                } else {
                    dst.rightRole = nil
                    dst.rightTagsAll = []
                    dst.rightTagsAny = []
                    dst.rightIncludeTerms = []
                    dst.rightExcludeTerms = []
                }
                dst.skipPairsIfSameTerm = js.skipPairsIfSameTerm
                dst.sourceTemplates = js.sourceTemplates
                dst.targetTemplates = js.targetTemplates
                dst.sourceJoiners = js.sourceJoiners.isEmpty ? [""] : js.sourceJoiners
                dst.isAppellation = js.isAppellation
                dst.preMask = js.preMask
                dst.needPairCheck = js.needPairCheck
                if patternMap[js.name] == nil { context.insert(dst); patternMap[js.name] = dst }
                try upsertPatternMeta(js, metaMap: &metaMap)
            }
        }

        private func upsertPatternMeta(_ js: JSPattern, metaMap: inout [String: SDPatternMeta]) throws {
            let grouping = SDPatternGrouping(rawValue: js.grouping.rawValue) ?? .optional
            let trimmedDisplay = js.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedDisplay.isEmpty ? js.name : trimmedDisplay
            let trimmedLabel = js.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let groupLabel = trimmedLabel.isEmpty ? "그룹" : trimmedLabel
            if let meta = metaMap[js.name] {
                if merge == .overwrite {
                    meta.displayName = displayName
                    meta.roles = js.roles
                    meta.grouping = grouping
                    meta.groupLabel = groupLabel
                    meta.defaultProhibitStandalone = js.defaultProhibitStandalone
                    meta.defaultIsAppellation = js.defaultIsAppellation
                    meta.defaultPreMask = js.defaultPreMask
                } else {
                    if meta.displayName == meta.name || meta.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        meta.displayName = displayName
                    }
                    if meta.roles.isEmpty { meta.roles = js.roles }
                    meta.grouping = grouping
                    if meta.groupLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meta.groupLabel == "그룹" {
                        meta.groupLabel = groupLabel
                    }
                }
            } else {
                let created = SDPatternMeta(
                    name: js.name,
                    displayName: displayName,
                    roles: js.roles,
                    grouping: grouping,
                    groupLabel: groupLabel,
                    defaultProhibitStandalone: js.defaultProhibitStandalone,
                    defaultIsAppellation: js.defaultIsAppellation,
                    defaultPreMask: js.defaultPreMask
                )
                context.insert(created)
                metaMap[js.name] = created
            }
        }
        
        private func fetchAllKeys<T: PersistentModel>(_ type: T.Type, key: KeyPath<T,String>) throws -> Set<String> {
            let list = try context.fetch(FetchDescriptor<T>())
            return Set(list.map { $0[keyPath: key] })
        }
        
        private func fetchTerms(for keys: [String]?) throws -> [SDTerm] {
            guard let keys, !keys.isEmpty else { return [] }
            var out: [SDTerm] = []
            for key in keys {
                let pred = #Predicate<SDTerm> { $0.key == key }
                var desc = FetchDescriptor<SDTerm>(predicate: pred)
                desc.fetchLimit = 1
                if let t = try context.fetch(desc).first { out.append(t) }
            }
            return out
        }
        
        private func key(of c: SDComponent) -> String {
            let roleKey = normalizedRoleKey(c.role)
            let groupNames = c.groupLinks.map { $0.group.name }
            let groupKey = groupKey(of: groupNames)
            return "\(c.pattern)|\(roleKey)|\(groupKey)"
        }

        private func key(of c: JSComponent) -> String {
            let roleKey = normalizedRoleKey(c.role)
            let groupKey = groupKey(of: c.groups)
            return "\(c.pattern)|\(roleKey)|\(groupKey)"
        }

        private func normalizedRoleKey(_ role: String?) -> String {
            guard let role else { return "-" }
            let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "-" : trimmed
        }

        private func groupKey(of names: [String]?) -> String {
            guard let names, !names.isEmpty else { return "-" }
            let trimmed = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !trimmed.isEmpty else { return "-" }
            let unique = Set(trimmed)
            return unique.sorted().joined(separator: ",")
        }
        
        private func ensureGroups(_ names: [String], for comp: SDComponent, pattern: String) throws {
            let cur = Set(comp.groupLinks.map({ $0.group.uid }))
            let new = Set(names.map({ "\(pattern)#\($0)" }))
            let removes = cur.subtracting(new)
            if !removes.isEmpty {
                for remove in removes {
                    if let removeLink = comp.groupLinks.first(where: { $0.group.uid == remove }) {
                        context.delete(removeLink)
                    }
                    let pred = #Predicate<SDGroup> { $0.uid == remove }
                    var desc = FetchDescriptor<SDGroup>(predicate: pred)
                    desc.fetchLimit = 1
                    if let g = try context.fetch(desc).first {
                        g.componentLinks.removeAll(where: { $0.component.term == comp.term })
                    }
                    comp.groupLinks.removeAll(where: { $0.group.uid == remove })
                }
            }
            
            var linked: [String: SDGroup] = [:]
            for link in comp.groupLinks { linked[link.group.uid] = link.group }
            for name in names {
                let uid = "\(pattern)#\(name)"
                let group = try findOrCreateGroup(uid: uid, pattern: pattern, name: name)
                if linked[uid] == nil {
                    let link = SDComponentGroup(component: comp, group: group)
                    context.insert(link)
                    comp.groupLinks.append(link)
                    group.componentLinks.append(link)
                }
            }
        }
        
        private func findOrCreateGroup(uid: String, pattern: String, name: String) throws -> SDGroup {
            let pred = #Predicate<SDGroup> { $0.uid == uid }
            var desc = FetchDescriptor<SDGroup>(predicate: pred)
            desc.fetchLimit = 1
            if let g = try context.fetch(desc).first { return g }
            let g = SDGroup(uid: uid, pattern: pattern, name: name)
            context.insert(g)
            return g
        }
        
        private func ensureTags(_ term: SDTerm, names: [String]) throws {
            var existing: [String: SDTag] = [:]
            for link in term.termTagLinks { existing[link.tag.name] = link.tag }
            for name in names {
                let tag = try findOrCreateTag(name)
                if existing[name] == nil {
                    let link = SDTermTagLink(term: term, tag: tag)
                    context.insert(link)
                    term.termTagLinks.append(link)
                    tag.termLinks.append(link)
                }
            }
        }
        
        private func findOrCreateTag(_ name: String) throws -> SDTag {
            let pred = #Predicate<SDTag> { $0.name == name }
            var desc = FetchDescriptor<SDTag>(predicate: pred)
            desc.fetchLimit = 1
            if let t = try context.fetch(desc).first { return t }
            let t = SDTag(name: name)
            context.insert(t)
            return t
        }
        
        private func mergeSet<T: Hashable>(_ a: [T], _ b: [T]) -> [T] {
            let set = LinkedHashSet<T>(a) + b
            return Array(set)
        }
        
        private func deleteMissing(bundle: JSBundle) throws {
            if sync.removeMissingTerms {
                let existingTerms = try context.fetch(FetchDescriptor<SDTerm>())
                let incoming = Set(bundle.terms.map { $0.key })
                let candidates = existingTerms.filter { !incoming.contains($0.key) }
                let filteredTerms: [SDTerm]
                if let filter = sync.termDeletionFilter {
                    filteredTerms = candidates.filter { filter($0.key) }
                } else {
                    filteredTerms = candidates
                }
                for term in filteredTerms {
                    try SourceIndexMaintainer.deleteAll(for: term, in: context)
                    context.delete(term)
                }
            }
            if sync.removeMissingPatterns {
                let existing = try fetchAllKeys(SDPattern.self, key: \SDPattern.name)
                let incoming = Set(bundle.patterns.map { $0.name })
                let candidates = existing.subtracting(incoming)
                let filtered = sync.patternDeletionFilter.map { filter in candidates.filter { filter($0) } } ?? Array(candidates)
                for name in filtered {
                    let pred = #Predicate<SDPattern> { $0.name == name }
                    for p in try context.fetch(FetchDescriptor<SDPattern>(predicate: pred)) { context.delete(p) }
                }
            }
        }
        
        private func cleanupOrphans() throws {
            for tag in try context.fetch(FetchDescriptor<SDTag>()) where tag.termLinks.isEmpty { context.delete(tag) }
            for group in try context.fetch(FetchDescriptor<SDGroup>()) where group.componentLinks.isEmpty { context.delete(group) }
        }
    }
    
    fileprivate struct LinkedHashSet<Element: Hashable>: Sequence {
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
    
    struct ImportDryRunView: View {
        let report: ImportDryRunReport
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Stat("Terms", report.terms)
                    Stat("Patterns", report.patterns)
                }
                if !report.warnings.isEmpty {
                    Divider()
                    Text("Warnings").font(.headline)
                    ForEach(Array(report.warnings.enumerated()), id: \.0) { _, w in
                        Text("• \(w)").foregroundStyle(.orange)
                    }
                }
                if !(report.termKeyCollisions.isEmpty && report.patternKeyCollisions.isEmpty) {
                    Divider()
                    Text("Key Collisions").font(.headline)
                    if !report.termKeyCollisions.isEmpty {
                        Text("Terms").font(.subheadline)
                        ForEach(report.termKeyCollisions.sorted(by: { $0.key < $1.key }), id: \.self) { c in
                            Text("• \(c.key) ×\(c.count)")
                        }
                    }
                    if !report.patternKeyCollisions.isEmpty {
                        Text("Patterns").font(.subheadline).padding(.top, 6)
                        ForEach(report.patternKeyCollisions.sorted(by: { $0.key < $1.key }), id: \.self) { c in
                            Text("• \(c.key) ×\(c.count)")
                        }
                    }
                }
            }
            .padding()
        }
        @ViewBuilder private func Stat(_ title: String, _ b: ImportDryRunReport.Bucket) -> some View {
            VStack {
                Text(title).font(.subheadline)
                HStack {
                    Label("+\(b.newCount)", systemImage: "plus.circle").foregroundStyle(.green)
                    Label("±\(b.updateCount)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                    Label("−\(b.deleteCount)", systemImage: "trash").foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    @MainActor final class ToastHub: ObservableObject {
        static let shared = ToastHub()
        @Published var message: String? = nil
        func show(_ text: String, seconds: Double = 2.0) {
            message = text
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if message == text { message = nil } }
        }
    }
    
    @MainActor
    struct ImportCoordinator {
        let context: ModelContext
        func performImport(bundle: JSBundle, merge: ImportMergePolicy, sync: ImportSyncPolicy = .init()) async {
            do {
                let upserter = GlossaryUpserter(context: context, merge: merge, sync: sync)
                let report = try upserter.dryRun(bundle: bundle)
                _ = try upserter.apply(bundle: bundle)
                ToastHub.shared.show("임포트 완료: Terms +\(report.terms.newCount+report.terms.updateCount), Patterns +\(report.patterns.newCount+report.patterns.updateCount)")
            } catch {
                ToastHub.shared.show("임포트 실패: \(error.localizedDescription)")
            }
        }
    }
    
    
}

extension View { func toast() -> some View { modifier(ToastOverlay()) } }
struct ToastOverlay: ViewModifier {
    @ObservedObject var hub = Glossary.SDModel.ToastHub.shared
    func body(content: Content) -> some View {
        ZStack {
            content
            if let msg = hub.message {
                Text(msg)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 6)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hub.message)
    }
}

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
        let markers: Bucket
        let warnings: [String]
        let termKeyCollisions: [KeyCollision]
        let patternKeyCollisions: [KeyCollision]
        let markerKeyCollisions: [KeyCollision]
    }
    
    struct ImportSyncPolicy: Sendable { var removeMissingTerms = false; var removeMissingPatterns = false; var removeMissingMarkers = false }
    
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
            try upsertMarkers(bundle.markers)
            if sync.removeMissingTerms || sync.removeMissingPatterns || sync.removeMissingMarkers {
                try deleteMissing(bundle: bundle)
                try cleanupOrphans()
            }
            try context.save()
            return report
        }
        
        // 결과 예상 시뮬레이션 함수
        func dryRun(bundle: JSBundle) throws -> ImportDryRunReport {
            let existingTermKeys = try fetchAllKeys(SDTerm.self, key: \SDTerm.key)
            let existingPatternIds = try fetchAllKeys(SDPattern.self, key: \SDPattern.name)
            let existingMarkerUids = try fetchAllKeys(SDAppellationMarker.self, key: \SDAppellationMarker.uid)
            let incomingTermKeys = bundle.terms.map { $0.key }
            let incomingPatternIds = bundle.patterns.map { $0.name }
            let incomingMarkerUids = bundle.markers.map { "\($0.source)|\($0.target)|\($0.position.rawValue)" }
            let incomingTermKeySet = Set(incomingTermKeys)
            let incomingPatternIdSet = Set(incomingPatternIds)
            let incomingMarkerUidSet = Set(incomingMarkerUids)
            let tNew = incomingTermKeySet.subtracting(existingTermKeys).count
            let tUpd = incomingTermKeySet.intersection(existingTermKeys).count
            let tDel = sync.removeMissingTerms ? existingTermKeys.subtracting(incomingTermKeySet).count : 0
            let pNew = incomingPatternIdSet.subtracting(existingPatternIds).count
            let pUpd = incomingPatternIdSet.intersection(existingPatternIds).count
            let pDel = sync.removeMissingPatterns ? existingPatternIds.subtracting(incomingPatternIdSet).count : 0
            let mNew = incomingMarkerUidSet.subtracting(existingMarkerUids).count
            let mUpd = incomingMarkerUidSet.intersection(existingMarkerUids).count
            let mDel = sync.removeMissingMarkers ? existingMarkerUids.subtracting(incomingMarkerUidSet).count : 0
            func collisions(_ arr: [String]) -> [ImportDryRunReport.KeyCollision] {
                var freq: [String:Int] = [:]
                for k in arr { freq[k, default: 0] += 1 }
                return freq.filter { $0.value > 1 }.map { .init(key: $0.key, count: $0.value) }.sorted { $0.key < $1.key }
            }
            let termCollisions = collisions(incomingTermKeys)
            let patternCollisions = collisions(incomingPatternIds)
            let markerCollisions = collisions(incomingMarkerUids)
            var warns: [String] = []
            for pat in bundle.patterns {
                let usesR = pat.sourceTemplates.contains { $0.contains("{R}") } || pat.targetTemplates.contains { $0.contains("{R}") }
                let right = pat.right
                let isUnary: Bool = {
                    guard let r = right else { return true }
                    let hasRoles = !(r.roles?.isEmpty ?? true)
                    let hasAll = !(r.tagsAll?.isEmpty ?? true)
                    let hasAny = !(r.tagsAny?.isEmpty ?? true)
                    let hasIncl = !(r.includeTermKeys?.isEmpty ?? true)
                    let hasExcl = !(r.excludeTermKeys?.isEmpty ?? true)
                    return !(hasRoles || hasAll || hasAny || hasIncl || hasExcl)
                }()
                if isUnary && usesR { warns.append("Pattern '\(pat.name)' appears unary but uses {R} in templates.") }
            }
            if !termCollisions.isEmpty { warns.append("Duplicate Term keys in import: \(termCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }
            if !patternCollisions.isEmpty { warns.append("Duplicate Pattern ids in import: \(patternCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }
            if !markerCollisions.isEmpty { warns.append("Duplicate Marker uids in import: \(markerCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }
            return ImportDryRunReport(
                terms: .init(newCount: tNew, updateCount: tUpd, deleteCount: tDel),
                patterns: .init(newCount: pNew, updateCount: pUpd, deleteCount: pDel),
                markers: .init(newCount: mNew, updateCount: mUpd, deleteCount: mDel),
                warnings: warns,
                termKeyCollisions: termCollisions,
                patternKeyCollisions: patternCollisions,
                markerKeyCollisions: markerCollisions
            )
        }
        
        private func upsertTerms(_ items: [JSTerm]) throws {
            var map: [String: SDTerm] = [:]
            for t in try context.fetch(FetchDescriptor<SDTerm>()) { map[t.key] = t }
            for src in items {
                if let dst = map[src.key] {
                    try update(term: dst, with: src)
                } else {
                    let dst = SDTerm(key: src.key, target: src.target)
                    try update(term: dst, with: src)
                    context.insert(dst)
                    map[src.key] = dst
                }
            }
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
            var existingByText: [String: SDSource] = [:]
            for s in dst.sources { existingByText[s.text] = s }
            for js in src.sources {
                if let s = existingByText[js.source] {
                    if merge == .overwrite { s.prohibitStandalone = js.prohibitStandalone }
                } else {
                    let s = SDSource(text: js.source, prohibitStandalone: js.prohibitStandalone, term: dst)
                    context.insert(s)
                    dst.sources.append(s)
                }
            }
            var existingCompKeys: [String: SDComponent] = [:]
            for c in dst.components { existingCompKeys[key(of: c)] = c }
            for jc in src.components {
                let compKey = key(of: jc)
                let comp: SDComponent
                if let c = existingCompKeys[compKey] {
                    comp = c
                    if merge == .overwrite {
                        comp.srcTplIdx = jc.srcTplIdx
                        comp.tgtTplIdx = jc.tgtTplIdx
                    }
                } else {
                    comp = SDComponent(pattern: jc.pattern, roles: jc.roles, srcTplIdx: jc.srcTplIdx, tgtTplIdx: jc.tgtTplIdx, term: dst)
                    context.insert(comp)
                    dst.components.append(comp)
                }
                if let groups = jc.groups { try ensureGroups(groups, for: comp, pattern: jc.pattern) }
            }
            try ensureTags(dst, names: src.tags)
        }
        
        private func upsertPatterns(_ items: [JSPattern]) throws {
            var map: [String: SDPattern] = [:]
            for p in try context.fetch(FetchDescriptor<SDPattern>()) { map[p.name] = p }
            for js in items {
                let dst = map[js.name] ?? SDPattern(name: js.name)
                if let l = js.left {
                    dst.leftRoles = l.roles ?? []
                    dst.leftTagsAll = l.tagsAll ?? []
                    dst.leftTagsAny = l.tagsAny ?? []
                    dst.leftIncludeTerms = try fetchTerms(for: l.includeTermKeys)
                    dst.leftExcludeTerms = try fetchTerms(for: l.excludeTermKeys)
                } else {
                    dst.leftRoles = []
                    dst.leftTagsAll = []
                    dst.leftTagsAny = []
                    dst.leftIncludeTerms = []
                    dst.leftExcludeTerms = []
                }
                if let r = js.right {
                    dst.rightRoles = r.roles ?? []
                    dst.rightTagsAll = r.tagsAll ?? []
                    dst.rightTagsAny = r.tagsAny ?? []
                    dst.rightIncludeTerms = try fetchTerms(for: r.includeTermKeys)
                    dst.rightExcludeTerms = try fetchTerms(for: r.excludeTermKeys)
                } else {
                    dst.rightRoles = []
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
                if map[js.name] == nil { context.insert(dst); map[js.name] = dst }
            }
        }
        
        private func upsertMarkers(_ items: [JSAppellationMarker]) throws {
            var map: [String: SDAppellationMarker] = [:]
            for m in try context.fetch(FetchDescriptor<SDAppellationMarker>()) { map[m.uid] = m }
            for js in items {
                let uid = "\(js.source)|\(js.target)|\(js.position.rawValue)"
                if let dst = map[uid] {
                    if merge == .overwrite { dst.prohibitStandalone = js.prohibitStandalone }
                } else {
                    let m = SDAppellationMarker(source: js.source, target: js.target, position: js.position.rawValue, prohibitStandalone: js.prohibitStandalone)
                    context.insert(m)
                    map[uid] = m
                }
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
        
        private func key(of c: SDComponent) -> String { "\(c.pattern)|\(c.roles?.joined(separator: ",") ?? "-")|\(c.srcTplIdx ?? -1)|\(c.tgtTplIdx ?? -1)" }
        private func key(of c: JSComponent) -> String { "\(c.pattern)|\(c.roles?.joined(separator: ",") ?? "-")|\(c.srcTplIdx ?? -1)|\(c.tgtTplIdx ?? -1)" }
        
        private func ensureGroups(_ names: [String], for comp: SDComponent, pattern: String) throws {
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
                let existing = try fetchAllKeys(SDTerm.self, key: \SDTerm.key)
                let incoming = Set(bundle.terms.map { $0.key })
                let toDelete = existing.subtracting(incoming)
                for key in toDelete {
                    let pred = #Predicate<SDTerm> { $0.key == key }
                    for t in try context.fetch(FetchDescriptor<SDTerm>(predicate: pred)) { context.delete(t) }
                }
            }
            if sync.removeMissingPatterns {
                let existing = try fetchAllKeys(SDPattern.self, key: \SDPattern.name)
                let incoming = Set(bundle.patterns.map { $0.name })
                let toDelete = existing.subtracting(incoming)
                for name in toDelete {
                    let pred = #Predicate<SDPattern> { $0.name == name }
                    for p in try context.fetch(FetchDescriptor<SDPattern>(predicate: pred)) { context.delete(p) }
                }
            }
            if sync.removeMissingMarkers {
                let existing = try fetchAllKeys(SDAppellationMarker.self, key: \SDAppellationMarker.uid)
                let incoming = Set(bundle.markers.map { "\($0.source)|\($0.target)|\($0.position.rawValue)" })
                let toDelete = existing.subtracting(incoming)
                for uid in toDelete {
                    let pred = #Predicate<SDAppellationMarker> { $0.uid == uid }
                    for m in try context.fetch(FetchDescriptor<SDAppellationMarker>(predicate: pred)) { context.delete(m) }
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
                    Stat("Markers", report.markers)
                }
                if !report.warnings.isEmpty {
                    Divider()
                    Text("Warnings").font(.headline)
                    ForEach(Array(report.warnings.enumerated()), id: \.0) { _, w in
                        Text("• \(w)").foregroundStyle(.orange)
                    }
                }
                if !(report.termKeyCollisions.isEmpty && report.patternKeyCollisions.isEmpty && report.markerKeyCollisions.isEmpty) {
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
                    if !report.markerKeyCollisions.isEmpty {
                        Text("Markers").font(.subheadline).padding(.top, 6)
                        ForEach(report.markerKeyCollisions.sorted(by: { $0.key < $1.key }), id: \.self) { c in
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
                ToastHub.shared.show("임포트 완료: Terms +\(report.terms.newCount+report.terms.updateCount), Patterns +\(report.patterns.newCount+report.patterns.updateCount), Markers +\(report.markers.newCount+report.markers.updateCount)")
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

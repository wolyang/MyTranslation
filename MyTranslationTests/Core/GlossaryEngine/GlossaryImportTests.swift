import Foundation
import SwiftData
import Testing
@testable import MyTranslation

struct GlossaryImportTests {
    @MainActor
    private func makeUpserter(
        merge: Glossary.SDModel.ImportMergePolicy = .keepExisting
    ) throws -> (Glossary.SDModel.GlossaryUpserter, ModelContext) {
        let schema = Schema([
            Glossary.SDModel.SDTerm.self,
            Glossary.SDModel.SDSource.self,
            Glossary.SDModel.SDComponent.self,
            Glossary.SDModel.SDComponentGroup.self,
            Glossary.SDModel.SDGroup.self,
            Glossary.SDModel.SDTag.self,
            Glossary.SDModel.SDTermTagLink.self,
            Glossary.SDModel.SDPattern.self,
            Glossary.SDModel.SDPatternMeta.self,
            Glossary.SDModel.SDSourceIndex.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        return (Glossary.SDModel.GlossaryUpserter(context: context, merge: merge), context)
    }

    private func seedExistingTerm(in context: ModelContext) -> Glossary.SDModel.SDTerm {
        let term = Glossary.SDModel.SDTerm(key: "hero", target: "기존")
        term.variants = ["old"]
        term.preMask = false
        let source = Glossary.SDModel.SDSource(text: "Hero", prohibitStandalone: false, term: term)
        let tag = Glossary.SDModel.SDTag(name: "legacy")
        let link = Glossary.SDModel.SDTermTagLink(term: term, tag: tag)
        term.sources.append(source)
        term.termTagLinks.append(link)
        tag.termLinks.append(link)
        context.insert(term)
        context.insert(source)
        context.insert(tag)
        context.insert(link)
        return term
    }

    private func sampleTerm(
        key: String,
        target: String,
        variants: [String],
        tags: [String],
        activatedBy: [String]? = nil,
        deactivatedIn: [String] = []
    ) -> JSTerm {
        JSTerm(
            key: key,
            sources: [JSSource(source: key.capitalized, prohibitStandalone: false)],
            target: target,
            variants: variants,
            tags: tags,
            components: [JSComponent(pattern: "person", role: "name", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)],
            isAppellation: false,
            preMask: false,
            deactivatedIn: deactivatedIn,
            activatedByKeys: activatedBy
        )
    }

    @Test @MainActor
    func dryRunCountsUnchangedTermsUsingSnapshots() throws {
        let (upserter, context) = try makeUpserter()

        let activator = Glossary.SDModel.SDTerm(key: "trigger", target: "트리거")
        let existing = Glossary.SDModel.SDTerm(key: "alpha", target: "알파")
        existing.variants = ["Alpha", "A"]
        existing.preMask = false
        let source = Glossary.SDModel.SDSource(text: "Alpha", prohibitStandalone: false, term: existing)
        let component = Glossary.SDModel.SDComponent(pattern: "person", role: "name", srcTplIdx: nil, tgtTplIdx: nil, term: existing)
        let tag = Glossary.SDModel.SDTag(name: "hero")
        let link = Glossary.SDModel.SDTermTagLink(term: existing, tag: tag)
        existing.sources.append(source)
        existing.components.append(component)
        existing.termTagLinks.append(link)
        existing.activators.append(activator)
        tag.termLinks.append(link)
        context.insert(activator)
        context.insert(existing)
        context.insert(source)
        context.insert(component)
        context.insert(tag)
        context.insert(link)

        let bundle = JSBundle(
            terms: [
                sampleTerm(
                    key: "alpha",
                    target: "알파",
                    variants: ["Alpha", "A"],
                    tags: ["hero"],
                    activatedBy: [" trigger ", ""]
                )
            ],
            patterns: []
        )

        let report = try upserter.dryRun(bundle: bundle)
        #expect(report.terms.unchangedCount == 1)
        #expect(report.terms.updateCount == 0)
        #expect(report.terms.newCount == 0)
        #expect(report.terms.deleteCount == 0)
    }

    @Test @MainActor
    func dryRunDetectsNewAndUpdatedTerms() throws {
        let (upserter, context) = try makeUpserter()
        let existing = Glossary.SDModel.SDTerm(key: "alpha", target: "old")
        context.insert(existing)

        let bundle = JSBundle(
            terms: [
                sampleTerm(key: "alpha", target: "new", variants: ["v1"], tags: [], deactivatedIn: ["ctx"]),
                sampleTerm(key: "beta", target: "beta-target", variants: [], tags: [])
            ],
            patterns: []
        )

        let report = try upserter.dryRun(bundle: bundle)
        #expect(report.terms.updateCount == 1)
        #expect(report.terms.newCount == 1)
        #expect(report.terms.unchangedCount == 0)
        #expect(report.terms.deleteCount == 0)
    }

    @Test @MainActor
    func applyRespectsMergePolicies() throws {
        let bundle = JSBundle(
            terms: [
                sampleTerm(
                    key: "hero",
                    target: "신규",
                    variants: ["new"],
                    tags: ["modern"],
                    deactivatedIn: ["宇宙人"]
                )
            ],
            patterns: []
        )

        let (keepUpserter, keepContext) = try makeUpserter(merge: .keepExisting)
        _ = seedExistingTerm(in: keepContext)
        _ = try keepUpserter.apply(bundle: bundle)
        let keepDesc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: #Predicate { $0.key == "hero" })
        let keepTerm = try keepContext.fetch(keepDesc).first!
        #expect(keepTerm.target == "기존")
        #expect(Set(keepTerm.variants) == Set(["old", "new"]))
        #expect(Set(keepTerm.termTagLinks.map { $0.tag.name }) == Set(["legacy", "modern"]))
        #expect(keepTerm.deactivatedIn == ["宇宙人"])

        let (overwriteUpserter, overwriteContext) = try makeUpserter(merge: .overwrite)
        _ = seedExistingTerm(in: overwriteContext)
        _ = try overwriteUpserter.apply(bundle: bundle)
        let overwriteDesc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: #Predicate { $0.key == "hero" })
        let overwriteTerm = try overwriteContext.fetch(overwriteDesc).first!
        #expect(overwriteTerm.target == "신규")
        #expect(overwriteTerm.variants == ["new"])
        #expect(Set(overwriteTerm.termTagLinks.map { $0.tag.name }) == Set(["modern"]))
        #expect(overwriteTerm.deactivatedIn == ["宇宙人"])
    }
}

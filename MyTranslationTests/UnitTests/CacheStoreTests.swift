import Foundation
import Testing
@testable import MyTranslation

struct CacheStoreTests {
    @Test
    func lookupReturnsStoredResult() {
        let cache = DefaultCacheStore()
        let result = TestFixtures.sampleTranslationResults[0]
        let key = "seg1|afm|style=neutral"

        cache.save(result: result, forKey: key)
        let found = cache.lookup(key: key)

        #expect(found?.text == result.text)
        #expect(found?.engine == result.engine)
    }

    @Test
    func lookupReturnsNilWhenKeyIsMissing() {
        let cache = DefaultCacheStore()
        #expect(cache.lookup(key: "missing") == nil)
    }

    @Test
    func saveOverwritesExistingValue() {
        let cache = DefaultCacheStore()
        let original = TestFixtures.makeTranslationResult(segmentID: "segX", text: "Original")
        let updated = TestFixtures.makeTranslationResult(segmentID: "segX", text: "Updated")
        let key = "segX|google|style=neutral"

        cache.save(result: original, forKey: key)
        cache.save(result: updated, forKey: key)

        let found = cache.lookup(key: key)
        #expect(found?.text == "Updated")
    }

    @Test
    func clearAllRemovesAllEntries() {
        let cache = DefaultCacheStore()
        cache.save(result: TestFixtures.sampleTranslationResults[0], forKey: "seg1|afm|style")
        cache.save(result: TestFixtures.sampleTranslationResults[1], forKey: "seg2|afm|style")

        cache.clearAll()

        #expect(cache.lookup(key: "seg1|afm|style") == nil)
        #expect(cache.lookup(key: "seg2|afm|style") == nil)
    }

    @Test
    func clearBySegmentIDsDeletesOnlyMatchingPrefixes() {
        let cache = DefaultCacheStore()
        cache.save(result: TestFixtures.sampleTranslationResults[0], forKey: "seg1|afm|style")
        cache.save(result: TestFixtures.sampleTranslationResults[1], forKey: "seg2|afm|style")
        cache.save(result: TestFixtures.sampleTranslationResults[2], forKey: "seg3|afm|style")
        cache.save(result: TestFixtures.makeTranslationResult(segmentID: "legacy", text: "Legacy"), forKey: "unparsed-key")

        cache.clearBySegmentIDs(["seg2"])

        #expect(cache.lookup(key: "seg1|afm|style") != nil)
        #expect(cache.lookup(key: "seg2|afm|style") == nil)
        #expect(cache.lookup(key: "seg3|afm|style") != nil)
        #expect(cache.lookup(key: "unparsed-key") != nil)
    }

    @Test
    func purgeRemovesEntriesOlderThanGivenDate() {
        let cache = DefaultCacheStore()
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let recentDate = Date()

        let oldResult = TestFixtures.makeTranslationResult(segmentID: "old", text: "Old", createdAt: oldDate)
        let newResult = TestFixtures.makeTranslationResult(segmentID: "new", text: "New", createdAt: recentDate)

        cache.save(result: oldResult, forKey: "old-key")
        cache.save(result: newResult, forKey: "new-key")

        cache.purge(before: Date(timeIntervalSinceNow: -1800))

        #expect(cache.lookup(key: "old-key") == nil)
        #expect(cache.lookup(key: "new-key")?.text == "New")
    }
}

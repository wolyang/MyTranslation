import Foundation
import Testing
@testable import MyTranslation

struct SentinelEncodingTests {
    @Test
    func sentinelEncodingRoundTripIsIdempotent() {
        let original = "그가 __ENT#41__을 찾았다. \"__ENT#10__\"도 봤다."
        let encoded = encodeSentinels(original)
        #expect(encoded == "그가 🟧ENT41🟧을 찾았다. \"🟧ENT10🟧\"도 봤다.")
        #expect(encodeSentinels(encoded) == encoded)

        let decoded = decodeSentinels(encoded)
        #expect(decoded == original)
        #expect(decodeSentinels(decoded) == decoded)
    }

    @Test
    func sentinelEncodingKeepsAdjacentTokensTight() {
        let original = "__ENT#4____ENT#5__"
        let encoded = encodeSentinels(original)
        #expect(encoded == "🟧ENT4🟧🟧ENT5🟧")

        let decoded = decodeSentinels(encoded)
        #expect(decoded == original)
    }

    @Test
    func sentinelEncodingPreservesZeroWidthCharacters() {
        let zwsp = "\u{200B}"
        let original = "__ENT#21__\(zwsp)은 \"__ENT#10__\"과"
        let encoded = encodeSentinels(original)
        #expect(encoded == "🟧ENT21🟧\(zwsp)은 \"🟧ENT10🟧\"과")

        let decoded = decodeSentinels(encoded)
        #expect(decoded == original)
    }

    @Test
    func sentinelEncodingIgnoresDamagedTokensUntilNormalization() {
        let original = "ENT#7__ 과 __ENT#8"
        let encoded = encodeSentinels(original)
        #expect(encoded == original)

        let masker = TermMasker()
        let normalized = masker.normalizeDamagedTokens(encoded)
        #expect(normalized == "__ENT#7__ 과 __ENT#8__")
    }

    @Test
    func sentinelPipelineProtectsTokensAndPreservesContext() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__ENT#21__": LockInfo(
                placeholder: "__ENT#21__",
                target: "초합금",
                endsWithBatchim: true,
                endsWithRieul: false,
                category: .term
            ),
            "__ENT#10__": LockInfo(
                placeholder: "__ENT#10__",
                target: "빛",
                endsWithBatchim: true,
                endsWithRieul: false,
                category: .term
            )
        ]

        let original = "__ENT#21__은 \"__ENT#10__\"과 함께 움직였다."
        let encoded = encodeSentinels(original)
        #expect(encoded == "🟧ENT21🟧은 \"🟧ENT10🟧\"과 함께 움직였다.")

        let simulatedTranslationOutput = encoded
        let decoded = decodeSentinels(simulatedTranslationOutput)
        #expect(decoded == original)

        var restored = masker.normalizeDamagedTokens(decoded)
        restored = masker.normalizeEntitiesAndParticles(
            in: restored,
            locksByToken: locks,
            names: [],
            mode: .tokensOnly
        )
        let unlocked = masker.unlockTermsSafely(restored, locks: locks)

        #expect(unlocked == "초합금은 \"빛\"과 함께 움직였다.")
    }
}

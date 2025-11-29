import Foundation
import Testing
@testable import MyTranslation

struct KoreanParticleRulesTests {

    @Test
    func chooseJosaResolvesCompositeParticles() {
        #expect(KoreanParticleRules.chooseJosa(for: "만가", baseHasBatchim: false, baseIsRieul: false) == "만이")
        #expect(KoreanParticleRules.chooseJosa(for: "만 는", baseHasBatchim: false, baseIsRieul: false) == "만 는")
        #expect(KoreanParticleRules.chooseJosa(for: "만로", baseHasBatchim: true, baseIsRieul: true) == "만으로")
        #expect(KoreanParticleRules.chooseJosa(for: "에게만", baseHasBatchim: true, baseIsRieul: false) == "에게만")
    }

    @Test
    func collapseSpacesWhenIsolatedSegmentRemovesExtraSpaces() {
        let text = ",   Alpha   !"

        let collapsed = KoreanParticleRules.collapseSpaces_PunctOrEdge_whenIsolatedSegment(text, target: "Alpha")

        #expect(collapsed == ",Alpha!")
    }

    @Test
    func collapseSpacesWhenIsolatedSegmentKeepsParticles() {
        let text = ", Alpha의 "

        let collapsed = KoreanParticleRules.collapseSpaces_PunctOrEdge_whenIsolatedSegment(text, target: "Alpha")

        #expect(collapsed == text)
    }
}

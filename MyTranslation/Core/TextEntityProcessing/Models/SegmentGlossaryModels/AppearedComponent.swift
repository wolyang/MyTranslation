//
//  AppearedComponent.swift
//  MyTranslation
//

import Foundation

struct AppearedComponent {
    let component: Glossary.SDModel.SDComponent
    let appearedTerm: AppearedTerm

    var pattern: String { component.pattern }
    var role: String? { component.role }
    var srcTplIdx: Int? { 0 } // FIXME: Pattern 리팩토링 임시 처리
    var tgtTplIdx: Int? { 0 } // FIXME: Pattern 리팩토링 임시 처리
    var groupLinks: [Glossary.SDModel.SDComponentGroup] { component.groupLinks }
}

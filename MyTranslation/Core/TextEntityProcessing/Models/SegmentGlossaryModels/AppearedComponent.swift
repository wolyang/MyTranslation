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
    var srcTplIdx: Int? { component.srcTplIdx }
    var tgtTplIdx: Int? { component.tgtTplIdx }
    var groupLinks: [Glossary.SDModel.SDComponentGroup] { component.groupLinks }
}

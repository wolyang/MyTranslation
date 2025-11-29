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
    var groupLinks: [Glossary.SDModel.SDComponentGroup] { component.groupLinks }
}

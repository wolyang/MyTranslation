//
//  AppearedTerm.swift
//  MyTranslation
//

import Foundation

struct AppearedTerm {
    let sdTerm: Glossary.SDModel.SDTerm
    let appearedSources: [Glossary.SDModel.SDSource]

    var key: String { sdTerm.key }
    var target: String { sdTerm.target }
    var variants: [String] { sdTerm.variants }
    var components: [Glossary.SDModel.SDComponent] { sdTerm.components }
    var preMask: Bool { sdTerm.preMask }
    var isAppellation: Bool { sdTerm.isAppellation }
    var activators: [Glossary.SDModel.SDTerm] { sdTerm.activators }
    var activates: [Glossary.SDModel.SDTerm] { sdTerm.activates }
}

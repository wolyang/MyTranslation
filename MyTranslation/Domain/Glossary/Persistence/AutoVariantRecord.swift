//
//  AutoVariantRecord.swift
//  MyTranslation
//
//  Created by sailor.m on 11/6/25.
//

import Foundation
import SwiftData

@Model
final class AutoVariantRecord {
    var source: String
    var target: String
    var count: Int

    init(source: String, target: String, count: Int) {
        self.source = source
        self.target = target
        self.count = count
    }
}

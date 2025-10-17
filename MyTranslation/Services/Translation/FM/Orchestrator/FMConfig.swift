//
//  FMConfig.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

public struct FMConfig {
    public var enablePostEdit: Bool
    public var enableComparer: Bool
    public var enableRerank: Bool

    public init(
        enablePostEdit: Bool = true,
        enableComparer: Bool = false,
        enableRerank: Bool = false
    ) {
        self.enablePostEdit = enablePostEdit
        self.enableComparer = enableComparer
        self.enableRerank = enableRerank
    }
}

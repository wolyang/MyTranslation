//
//  Untitled.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import SwiftUI

public final class UserSettings: ObservableObject {
    @AppStorage("useFM") public var useFM: Bool = true
    @AppStorage("preferredEngine") private var preferredEngineRawValue: String = EngineTag.afm.rawValue

    public var preferredEngine: EngineTag {
        get { EngineTag(rawValue: preferredEngineRawValue) ?? .afm }
        set { preferredEngineRawValue = newValue.rawValue }
    }

    public init() {}
}

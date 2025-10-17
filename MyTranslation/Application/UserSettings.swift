//
//  Untitled.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import SwiftUI

public final class UserSettings: ObservableObject {
    @AppStorage("useFM") public var useFM: Bool = true
    public init() {}
}

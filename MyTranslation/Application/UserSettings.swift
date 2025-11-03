//
//  UserSettings.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import SwiftUI

public final class UserSettings: ObservableObject {
    public struct FavoriteLink: Identifiable, Codable, Equatable {
        public var id: UUID
        public var title: String
        public var url: String

        public init(id: UUID = UUID(), title: String, url: String) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    @AppStorage("useFM") public var useFM: Bool = true
    @AppStorage("preferredEngine") private var preferredEngineRawValue: String = EngineTag.afm.rawValue
    @AppStorage("favoriteLinks") private var favoriteLinksData: Data = Data()
    @AppStorage("lastVisitedURL") public var lastVisitedURL: String = ""
    @AppStorage("recentURLLimit") public var recentURLLimit: Int = 8

    public var preferredEngine: EngineTag {
        get { EngineTag(rawValue: preferredEngineRawValue) ?? .afm }
        set { preferredEngineRawValue = newValue.rawValue }
    }

    public var favoriteLinks: [FavoriteLink] {
        get {
            (try? JSONDecoder().decode([FavoriteLink].self, from: favoriteLinksData)) ?? []
        }
        set {
            favoriteLinksData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    public init() {}
}

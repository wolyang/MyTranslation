// File: MoreMenuView.swift
import SwiftUI

struct MoreMenuView: View { // NEW
    let favorites: [BrowserViewModel.PresetLink]
    let onSelectFavorite: (BrowserViewModel.PresetLink) -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if favorites.isEmpty == false {
                    Section("즐겨찾기") {
                        ForEach(favorites) { link in
                            Button {
                                onSelectFavorite(link)
                            } label: {
                                Label(link.title, systemImage: "star")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }

                Section("기타") {
                    Button {
                        onOpenGlossary()
                    } label: {
                        Label("용어집 열기", systemImage: "book")
                            .labelStyle(.titleAndIcon)
                    }

                    Button {
                        onOpenSettings()
                    } label: {
                        Label("설정", systemImage: "gearshape")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("더보기")
        }
    }
}

struct MoreSidebarView: View { // NEW
    let favorites: [BrowserViewModel.PresetLink]
    let onSelectFavorite: (BrowserViewModel.PresetLink) -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        List {
            if favorites.isEmpty == false {
                Section("즐겨찾기") {
                    ForEach(favorites) { link in
                        Button {
                            onSelectFavorite(link)
                        } label: {
                            Label(link.title, systemImage: "star")
                        }
                    }
                }
            }

            Section("기타") {
                Button {
                    onOpenGlossary()
                } label: {
                    Label("용어집 열기", systemImage: "book")
                }

                Button {
                    onOpenSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

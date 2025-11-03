// File: MoreMenuView.swift
import SwiftUI

struct MoreMenuView: View { // NEW
    let favorites: [BrowserViewModel.PresetLink]
    let onSelectFavorite: (BrowserViewModel.PresetLink) -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: Route.favorites) {
                    Label("즐겨찾기", systemImage: "star")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    onOpenGlossary()
                } label: {
                    Label("용어집", systemImage: "book")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    onOpenSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .favorites:
                    favoritesList
                }
            }
        }
    }

    private var favoritesList: some View {
        List {
            if favorites.isEmpty {
                Text("등록된 즐겨찾기가 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(favorites) { link in
                    Button {
                        onSelectFavorite(link)
                        path.removeAll()
                    } label: {
                        Text(link.title)
                    }
                }
            }
        }
    }

    private enum Route: Hashable {
        case favorites
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
                    Label("용어집", systemImage: "book")
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

// File: MoreMenuView.swift
import SwiftUI

/// iPhone 크기에서 더보기 바텀 시트로 노출되는 메뉴입니다.
struct MoreMenuView: View {
    let favorites: [UserSettings.FavoriteLink]
    let onSelectFavorite: (UserSettings.FavoriteLink) -> Void
    let onAddFavorite: () -> Bool
    let onUpdateFavorite: (UserSettings.FavoriteLink, String, String) -> Void
    let onDeleteFavorites: (IndexSet) -> Void
    let onMoveFavorites: (IndexSet, Int) -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onFindInPage: () -> Void
    let isDesktopMode: Bool
    let onToggleDesktopMode: (Bool) -> Void

    /// 바텀시트 내 NavigationStack 경로입니다.
    @State private var path: [Route] = []
    @State private var addResult: AddResult? = nil

    /// 즐겨찾기 목록과 서브 화면을 관리하는 본문 뷰입니다.
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("즐겨찾기") {
                    Button {
                        let isNew = onAddFavorite()
                        addResult = isNew ? .added : .duplicated
                    } label: {
                        Label("현재 페이지 즐겨찾기 추가", systemImage: "star.badge.plus")
                            .labelStyle(.titleAndIcon)
                    }

                    NavigationLink(value: Route.favorites) {
                        Label("즐겨찾기 관리", systemImage: "star")
                            .labelStyle(.titleAndIcon)
                    }
                }

                Button {
                    onOpenGlossary()
                } label: {
                    Label("용어집", systemImage: "book")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    onOpenHistory()
                } label: {
                    Label("히스토리", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    onOpenSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                }

                Section("페이지") {
                    Button {
                        onFindInPage()
                    } label: {
                        Label("페이지 내 검색", systemImage: "magnifyingglass")
                    }

                    Toggle(isOn: Binding(get: { isDesktopMode }, set: { onToggleDesktopMode($0) })) {
                        Label("데스크톱 모드", systemImage: "desktopcomputer")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .favorites:
                    FavoritesManagerView(
                        favorites: favorites,
                        onSelectFavorite: { favorite in
                            onSelectFavorite(favorite)
                            path.removeAll()
                        },
                        onUpdateFavorite: onUpdateFavorite,
                        onDeleteFavorites: onDeleteFavorites,
                        onMoveFavorites: onMoveFavorites
                    )
                }
            }
            .alert(item: $addResult) { result in
                switch result {
                case .added:
                    return Alert(title: Text("즐겨찾기에 추가했습니다."))
                case .duplicated:
                    return Alert(title: Text("이미 즐겨찾기에 등록된 페이지입니다."))
                }
            }
        }
    }

    private enum Route: Hashable {
        /// iPhone 시트에서 탐색 가능한 메뉴 종류입니다.
        case favorites
    }

    private enum AddResult: Identifiable {
        case added
        case duplicated

        var id: Int { hashValue }
    }
}

/// iPad 사이즈에서 사이드바 항목으로 더보기 기능을 노출합니다.
struct MoreSidebarView: View {
    let favorites: [UserSettings.FavoriteLink]
    let onSelectFavorite: (UserSettings.FavoriteLink) -> Void
    let onAddFavorite: () -> Bool
    let onManageFavorites: () -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onFindInPage: () -> Void
    let isDesktopMode: Bool
    let onToggleDesktopMode: (Bool) -> Void

    /// 사이드바 항목을 구성하는 본문 뷰입니다.
    var body: some View {
        List {
            Section("즐겨찾기") {
                Button {
                    _ = onAddFavorite()
                } label: {
                    Label("현재 페이지 즐겨찾기 추가", systemImage: "star.badge.plus")
                }

                if favorites.isEmpty {
                    Text("등록된 즐겨찾기가 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(favorites) { link in
                        Button { onSelectFavorite(link) } label: {
                            Label(link.title, systemImage: "star")
                        }
                    }
                }

                Button {
                    onManageFavorites()
                } label: {
                    Label("즐겨찾기 관리", systemImage: "slider.horizontal.3")
                }
            }

            Section("기타") {
                Button {
                    onOpenGlossary()
                } label: {
                    Label("용어집", systemImage: "book")
                }

                Button {
                    onOpenHistory()
                } label: {
                    Label("히스토리", systemImage: "clock")
                }

                Button {
                    onOpenSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                }

                Button {
                    onFindInPage()
                } label: {
                    Label("페이지 내 검색", systemImage: "magnifyingglass")
                }

                Toggle(isOn: Binding(get: { isDesktopMode }, set: { onToggleDesktopMode($0) })) {
                    Label("데스크톱 모드", systemImage: "desktopcomputer")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

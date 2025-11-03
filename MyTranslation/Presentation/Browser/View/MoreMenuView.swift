// File: MoreMenuView.swift
import SwiftUI

/// iPhone 크기에서 더보기 바텀 시트로 노출되는 메뉴입니다.
struct MoreMenuView: View {
    let favorites: [BrowserViewModel.PresetLink]
    let onSelectFavorite: (BrowserViewModel.PresetLink) -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void

    /// 바텀시트 내 NavigationStack 경로입니다.
    @State private var path: [Route] = []

    /// 즐겨찾기 목록과 서브 화면을 관리하는 본문 뷰입니다.
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
        /// 즐겨찾기 세부 목록을 보여주고 선택 즉시 상위로 닫습니다.
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
        /// iPhone 시트에서 탐색 가능한 메뉴 종류입니다.
        case favorites
    }
}

/// iPad 사이즈에서 사이드바 항목으로 더보기 기능을 노출합니다.
struct MoreSidebarView: View {
    let favorites: [BrowserViewModel.PresetLink]
    let onSelectFavorite: (BrowserViewModel.PresetLink) -> Void
    let onOpenGlossary: () -> Void
    let onOpenSettings: () -> Void

    /// 사이드바 항목을 구성하는 본문 뷰입니다.
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

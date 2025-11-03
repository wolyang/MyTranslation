// File: FavoritesManagerView.swift
import SwiftUI

/// 즐겨찾기 목록을 선택/편집할 수 있는 관리 화면입니다.
struct FavoritesManagerView: View {
    let favorites: [UserSettings.FavoriteLink]
    let onSelectFavorite: (UserSettings.FavoriteLink) -> Void
    let onUpdateFavorite: (UserSettings.FavoriteLink, String, String) -> Void
    let onDeleteFavorites: (IndexSet) -> Void
    let onMoveFavorites: (IndexSet, Int) -> Void

    @State private var editingFavorite: UserSettings.FavoriteLink? = nil

    var body: some View {
        List {
            if favorites.isEmpty {
                Text("등록된 즐겨찾기가 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(favorites) { favorite in
                    Button {
                        onSelectFavorite(favorite)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.title)
                                .foregroundColor(.primary)
                            Text(favorite.url)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let index = favorites.firstIndex(of: favorite) {
                                onDeleteFavorites(IndexSet(integer: index))
                            }
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }

                        Button {
                            editingFavorite = favorite
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete(perform: onDeleteFavorites)
                .onMove(perform: onMoveFavorites)
            }
        }
        .animation(.default, value: favorites)
        .navigationTitle("즐겨찾기")
        .toolbar { EditButton() }
        .sheet(item: $editingFavorite) { favorite in
            FavoriteEditView(
                favorite: favorite,
                onSave: { title, url in
                    onUpdateFavorite(favorite, title, url)
                }
            )
            .presentationDetents([.medium])
        }
    }
}

private struct FavoriteEditView: View {
    let favorite: UserSettings.FavoriteLink
    var onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var url: String

    init(favorite: UserSettings.FavoriteLink, onSave: @escaping (String, String) -> Void) {
        self.favorite = favorite
        self.onSave = onSave
        _title = State(initialValue: favorite.title)
        _url = State(initialValue: favorite.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") {
                    TextField("제목", text: $title)
                }

                Section("URL") {
                    TextField("https://…", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("즐겨찾기 편집")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(title, url)
                        dismiss()
                    }
                }
            }
        }
    }
}

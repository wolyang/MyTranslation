import SwiftUI

struct TermPickerItem: Identifiable, Hashable {
    let key: String
    let target: String
    let sourcePreview: String
    var id: String { key }
}

struct TermPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let terms: [TermPickerItem]
    let onSelect: (String) -> Void

    @State private var searchText = ""

    var filteredTerms: [TermPickerItem] {
        if searchText.isEmpty {
            return terms
        }
        return terms.filter { term in
            term.target.localizedCaseInsensitiveContains(searchText) ||
            term.key.localizedCaseInsensitiveContains(searchText) ||
            term.sourcePreview.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredTerms) { term in
                    Button {
                        onSelect(term.key)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.target)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if term.sourcePreview.isEmpty == false {
                                Text(term.sourcePreview)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "용어 검색")
            .navigationTitle("Term 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

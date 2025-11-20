import SwiftUI

struct TermPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let terms: [(key: String, target: String)]
    let onSelect: (String) -> Void

    @State private var searchText = ""

    var filteredTerms: [(key: String, target: String)] {
        if searchText.isEmpty {
            return terms
        }
        return terms.filter { term in
            term.target.localizedCaseInsensitiveContains(searchText) ||
            term.key.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredTerms, id: \.key) { term in
                    Button {
                        onSelect(term.key)
                        dismiss()
                    } label: {
                        Text(term.target)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

import SwiftUI

struct GlossaryAddSheet: View {
    let state: GlossaryAddSheetState
    let onAddNew: (String?) -> Void
    let onAppendToExisting: () -> Void
    let onAppendCandidate: (String) -> Void
    let onEditExisting: (String) -> Void
    let onCancel: () -> Void

    @State private var sourceInput: String
    @FocusState private var isSourceFieldFocused: Bool

    init(
        state: GlossaryAddSheetState,
        onAddNew: @escaping (String?) -> Void,
        onAppendToExisting: @escaping () -> Void,
        onAppendCandidate: @escaping (String) -> Void,
        onEditExisting: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onAddNew = onAddNew
        self.onAppendToExisting = onAppendToExisting
        self.onAppendCandidate = onAppendCandidate
        self.onEditExisting = onEditExisting
        self.onCancel = onCancel
        _sourceInput = State(initialValue: state.selectionKind == .translated ? state.originalText : "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader
                selectedTextCard
                if state.selectionKind == .translated {
                    sourceInputField
                }
                if state.selectionKind == .original {
                    originalActionButtons
                } else {
                    translatedActionButtons
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .navigationTitle("용어집에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                }
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.sectionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("선택한 텍스트")
                .font(.headline)
        }
    }

    private var selectedTextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.selectedText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .lineLimit(6)
            Text("선택한 내용으로 용어를 추가할 수 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var originalActionButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let matched = state.matchedTerm {
                matchedTermCard(entry: matched.entry)
                Button {
                    onEditExisting(matched.key)
                } label: {
                    Label("이 용어 편집", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("선택한 원문에 해당하는 기존 용어가 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                onAddNew(nil)
            } label: {
                Label("새 용어로 추가", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var translatedActionButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.unmatchedCandidates.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    Text("추천 용어")
                        .font(.subheadline.weight(.semibold))
                    ForEach(state.unmatchedCandidates) { candidate in
                        candidateRow(candidate)
                    }
                }
            } else if let message = state.recommendationMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("추천 없음")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                onAddNew(sourceInput.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Label("새 용어로 추가", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAddNewDisabled)

            Button {
                onAppendToExisting()
            } label: {
                Label("기존 용어에 변형 추가", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func matchedTermCard(entry: GlossaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("기존 용어")
                .font(.subheadline.weight(.semibold))
            infoRow(label: "원문", value: entry.source)
            infoRow(label: "번역", value: entry.target)
            let variants = entry.variants.sorted()
            if variants.isEmpty == false {
                infoRow(label: "변형", value: variants.joined(separator: ", "))
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.primary)
        }
    }

    private func candidateRow(_ candidate: GlossaryAddSheetState.UnmatchedTermCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.entry.source)
                    .font(.body.weight(.semibold))
                Spacer()
                Text("유사도 \(Int(candidate.similarity * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.entry.target)
                .font(.callout)
                .foregroundStyle(.primary)
            if candidate.entry.variants.isEmpty == false {
                Text(candidate.entry.variants.sorted().joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let key = candidate.termKey {
                Button {
                    onAppendCandidate(key)
                } label: {
                    Label("이 용어에 변형 추가", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Text("이 용어는 직접 편집만 가능합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var sourceInputField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("원문 범위 선택")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            TextEditor(text: $sourceInput)
                .frame(minHeight: 80, maxHeight: 140)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .focused($isSourceFieldFocused)
            Text("필요한 원문 구간만 입력하세요. 지정하지 않으면 기본 원문 전체가 사용됩니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var isAddNewDisabled: Bool {
        if state.selectionKind == .translated {
            return sourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
}

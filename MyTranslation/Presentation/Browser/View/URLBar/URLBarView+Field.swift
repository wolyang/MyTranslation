// File: URLBarView+Field.swift
import SwiftUI

extension URLBarView {
    /// 포커스 상태 변화에 따라 편집 상태와 URL 복원을 제어합니다.
    func handleFocusChange(oldValue: Bool, newValue: Bool) {
        if newValue {
            originalURLBeforeEditing = urlString
            didCommitDuringEditing = false
            isShowingEngineOptions = false
        } else if oldValue && didCommitDuringEditing == false {
            urlString = originalURLBeforeEditing
        }
        isEditing = newValue
    }

    /// 외부 편집 상태 변경에 따라 포커스를 동기화합니다.
    func handleEditingChange(_ newValue: Bool) {
        if newValue && !isFocused {
            isFocused = true
        } else if !newValue && isFocused {
            isFocused = false
        }
        if newValue {
            isShowingEngineOptions = false
        }
    }

    /// 입력을 확정하고 URL을 로드하면서 최근 목록을 업데이트합니다.
    func commitGo() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urlString = trimmed
        updateRecents(with: trimmed)
        didCommitDuringEditing = true
        isFocused = false
        onGo(trimmed)
    }

    /// 추천 목록에서 선택한 URL을 즉시 입력에 반영합니다.
    func applySuggestion(_ url: String) {
        urlString = url
        commitGo()
    }

    /// 외부 컨트롤에서 키보드를 내릴 때 호출됩니다.
    func endEditing() {
        isFocused = false
    }
}

/// URL 입력 텍스트 필드를 구성하는 뷰입니다.
struct URLBarField: View {
    @Binding var urlString: String
    var isFocused: FocusState<Bool>.Binding
    var goButtonSymbolName: String
    var onCommit: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("https://…", text: $urlString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .focused(isFocused)
                .submitLabel(.go)
                .onSubmit { onCommit() }
                .layoutPriority(1)

            if isFocused.wrappedValue && !urlString.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isFocused.wrappedValue {
                let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                Button(action: onCommit) {
                    Image(systemName: goButtonSymbolName)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
    }
}

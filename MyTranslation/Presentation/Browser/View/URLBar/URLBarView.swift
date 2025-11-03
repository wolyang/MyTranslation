// File: URLBarView.swift
import SwiftUI

/// 브라우저 상단의 URL 입력·엔진 선택·부가 메뉴를 묶은 바입니다.
struct URLBarView: View {
    @Binding var urlString: String
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isEditing: Bool
    @Binding var isTranslating: Bool

    var currentPageURLString: String
    var onGo: (String) -> Void
    var onSelectEngine: (EngineTag, Bool) -> Void = { _, _ in }
    var onTapMore: (() -> Void)? = nil

    @FocusState var isFocused: Bool
    @AppStorage("recentURLs") var recentURLsData: Data = Data()
    @AppStorage("recentURLLimit") var recentURLLimit: Int = 8

    @State var fieldHeight: CGFloat = 0
    @State var barHeight: CGFloat = 0
    @State var originalURLBeforeEditing: String = ""
    @State var didCommitDuringEditing: Bool = false
    @State var isShowingEngineOptions: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                URLBarField(
                    urlString: $urlString,
                    isFocused: $isFocused,
                    goButtonSymbolName: goButtonSymbolName,
                    onCommit: commitGo,
                    onClear: { urlString = "" }
                )
                .background(fieldHeightReader)
                .overlay(alignment: .topLeading) {
                    if shouldShowSuggestions {
                        URLSuggestionsView(urls: filteredRecents, onSelect: applySuggestion)
                            .offset(y: fieldHeight + 6)
                    }
                }
                .frame(maxWidth: .infinity)

                URLBarControlGroup(
                    selectedEngine: $selectedEngine,
                    showOriginal: $showOriginal,
                    isShowingEngineOptions: $isShowingEngineOptions,
                    isTranslating: $isTranslating,
                    onInteract: endEditing,
                    onTapMore: onTapMore
                )
            }
            .background(barHeightReader)
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingEngineOptions)
        .overlay(alignment: .topLeading) {
            if isShowingEngineOptions {
                EnginePickerOptionsContainer {
                    EnginePickerOptionsView(
                        selectedEngine: $selectedEngine,
                        showOriginal: $showOriginal,
                        onInteract: endEditing,
                        onSelectEngine: { engine, wasShowingOriginal in
                            onSelectEngine(engine, wasShowingOriginal)
                        },
                        dismiss: { withAnimation(.easeInOut(duration: 0.2)) { isShowingEngineOptions = false } }
                    )
                }
                .offset(y: barHeight + 6)
                .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .onChange(of: selectedEngine) { _, _ in
            isShowingEngineOptions = false
        }
        .onChange(of: showOriginal) { _, _ in
            isShowingEngineOptions = false
        }
        .onChange(of: isFocused) { oldValue, newValue in
            handleFocusChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: isEditing) { _, newValue in
            handleEditingChange(newValue)
        }
        .onChange(of: recentURLLimit) { _, newValue in
            trimRecents(to: newValue)
        }
        .zIndex(2)
    }
}

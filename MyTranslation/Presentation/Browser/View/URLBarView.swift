// File: URLBarView.swift
import SwiftUI

struct URLBarView: View {
    @Binding var urlString: String
    var presetURLs: [BrowserViewModel.PresetLink] = []
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isEditing: Bool
    var currentPageURLString: String
    var onGo: (String) -> Void
    var onSelectEngine: (EngineTag, Bool) -> Void = { _, _ in }
    var onTapMore: (() -> Void)? = nil
    @FocusState private var isFocused: Bool
    @AppStorage("recentURLs") private var recentURLsData: Data = Data()
    @State private var fieldHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @State private var originalURLBeforeEditing: String = ""
    @State private var didCommitDuringEditing: Bool = false
    @State private var isShowingEngineOptions: Bool = false

    private let maxRecentCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                field
                    .background(fieldHeightReader)
                    .overlay(alignment: .topLeading) {
                        if shouldShowSuggestions {
                            suggestions
                                .offset(y: fieldHeight + 6)
                        }
                    }
                    .frame(maxWidth: .infinity)

                controlGroup
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
        .zIndex(2)
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("https://…", text: $urlString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .focused($isFocused)
                .submitLabel(.go)
                .onSubmit { commitGo() }
                .layoutPriority(1)

            if isFocused && !urlString.isEmpty {
                Button {
                    urlString = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isFocused {
                Button(action: commitGo) {
                    Image(systemName: goButtonSymbolName)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
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
        .onChange(of: isFocused) { oldValue, newValue in
            if newValue {
                originalURLBeforeEditing = urlString
                didCommitDuringEditing = false
                isShowingEngineOptions = false
            } else if oldValue && didCommitDuringEditing == false {
                urlString = originalURLBeforeEditing
            }
            isEditing = newValue
        }
        .onChange(of: isEditing) { _, newValue in
            if newValue && !isFocused {
                isFocused = true
            } else if !newValue && isFocused {
                isFocused = false
            }
            if newValue {
                isShowingEngineOptions = false
            }
        }
    }

    private var suggestions: some View {
        let recents = filteredRecents
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(recents, id: \.self) { url in
                Button {
                    applySuggestion(url)
                } label: {
                    Text(url)
                        .font(.footnote)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if url != recents.last {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemBackground))
        )
        .shadow(color: Color.black.opacity(0.1), radius: 10, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlGroup: some View {
        HStack(spacing: 4) {
            if presetURLs.isEmpty == false {
                Menu {
                    Section("테스트 URL") {
                        ForEach(presetURLs) { preset in
                            Button(preset.title) {
                                applyPreset(preset)
                            }
                        }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "bookmark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Color.accentColor)
                        Text("테스트")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
            }

            EnginePickerButton(
                selectedEngine: $selectedEngine,
                showOriginal: $showOriginal,
                isShowingOptions: $isShowingEngineOptions,
                onInteract: endEditing,
                onSelectEngine: { engine, wasShowingOriginal in
                    onSelectEngine(engine, wasShowingOriginal)
                }
            )

            if let onTapMore {
                Button {
                    onTapMore()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "ellipsis.circle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Color.accentColor)
                        Text("더보기")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("더보기 메뉴 열기")
            }
        }
    }

    private var filteredRecents: [String] {
        let query = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = storedRecentURLs
        guard !query.isEmpty else { return Array(urls.prefix(maxRecentCount)) }
        return urls.filter { $0.localizedCaseInsensitiveContains(query) }
            .prefix(maxRecentCount)
            .map { $0 }
    }

    private var shouldShowSuggestions: Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return isFocused && !trimmed.isEmpty && !filteredRecents.isEmpty
    }

    private var storedRecentURLs: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: recentURLsData)) ?? []
        }
        nonmutating set {
            recentURLsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private var fieldHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { fieldHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newValue in
                    fieldHeight = newValue
                }
        }
    }

    private var barHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { barHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newValue in
                    barHeight = newValue
                }
        }
    }

    private func commitGo() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urlString = trimmed
        updateRecents(with: trimmed)
        didCommitDuringEditing = true
        isFocused = false
        onGo(trimmed)
    }

    private func applySuggestion(_ url: String) {
        urlString = url
        commitGo()
    }

    private func applyPreset(_ preset: BrowserViewModel.PresetLink) {
        guard urlString != preset.url else {
            commitGo()
            return
        }
        urlString = preset.url
        commitGo()
    }

    private func updateRecents(with newURL: String) {
        guard !newURL.isEmpty else { return }
        var urls = storedRecentURLs
        urls.removeAll { $0.caseInsensitiveCompare(newURL) == .orderedSame }
        urls.insert(newURL, at: 0)
        if urls.count > maxRecentCount {
            urls = Array(urls.prefix(maxRecentCount))
        }
        storedRecentURLs = urls
    }

    private func endEditing() {
        isFocused = false
    }

    private var goButtonSymbolName: String {
        let trimmedCurrent = currentPageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = originalURLBeforeEditing.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return "arrow.right.circle.fill" }
        let isUnchanged = trimmedInput == trimmedOriginal
        let matchesCurrent = trimmedInput == trimmedCurrent && !trimmedCurrent.isEmpty
        return isUnchanged && matchesCurrent ? "arrow.clockwise.circle.fill" : "arrow.right.circle.fill"
    }
}

private struct EnginePickerButton: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isShowingOptions: Bool
    var onInteract: () -> Void = {}
    var onSelectEngine: (EngineTag, Bool) -> Void = { _, _ in }

    var body: some View {
        Button {
            onInteract()
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingOptions.toggle()
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(showOriginal ? Color.gray : Color.accentColor)
                Text(showOriginal ? "원문" : selectedEngine.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(showOriginal ? Color.gray : Color.accentColor)
            }
            .frame(width: 30)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EnginePickerOptionsContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                content()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct EnginePickerOptionsView: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    var onInteract: () -> Void
    var onSelectEngine: (EngineTag, Bool) -> Void
    var dismiss: () -> Void

    var body: some View {
        let engines = Array(EngineTag.allCases)

        return VStack(spacing: 0) {
            OptionButton(title: "원문 보기", isSelected: showOriginal) {
                onInteract()
                if showOriginal == false {
                    showOriginal = true
                }
                dismiss()
            }

            Divider()

            ForEach(engines.indices, id: \.self) { index in
                let engine = engines[index]
                OptionButton(title: engine.displayName, isSelected: !showOriginal && engine == selectedEngine) {
                    onInteract()
                    let wasShowingOriginal = showOriginal
                    selectedEngine = engine
                    onSelectEngine(engine, wasShowingOriginal)
                    if wasShowingOriginal {
                        showOriginal = false
                    }
                    dismiss()
                }

                if index < engines.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 6)
    }

    private struct OptionButton: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack {
                    Text(title)
                        .foregroundColor(.primary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

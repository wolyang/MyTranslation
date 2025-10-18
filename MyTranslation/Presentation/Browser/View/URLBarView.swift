// File: URLBarView.swift
import SwiftUI

struct URLBarView: View {
    @Binding var urlString: String
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isEditing: Bool
    var currentPageURLString: String
    var onGo: (String) -> Void
    var onSelectEngine: (EngineTag, Bool) -> Void = { _, _ in }
    @FocusState private var isFocused: Bool
    @AppStorage("recentURLs") private var recentURLsData: Data = Data()
    @State private var fieldHeight: CGFloat = 0
    @State private var originalURLBeforeEditing: String = ""
    @State private var didCommitDuringEditing: Bool = false

    private let maxRecentCount = 8

    var body: some View {
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
            EnginePickerButton(
                selectedEngine: $selectedEngine,
                showOriginal: $showOriginal,
                onInteract: endEditing,
                onSelectEngine: { engine, wasShowingOriginal in
                    onSelectEngine(engine, wasShowingOriginal)
                }
            )
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
    var onInteract: () -> Void = {}
    var onSelectEngine: (EngineTag, Bool) -> Void = { _, _ in }

    var body: some View {
        Menu {
            Button {
                onInteract()
                if showOriginal == false {
                    showOriginal = true
                }
            } label: {
                HStack {
                    Text("원문 보기")
                    Spacer()
                    if showOriginal {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(EngineTag.allCases, id: \.self) { engine in
                Button {
                    onInteract()
                    let wasShowingOriginal = showOriginal
                    selectedEngine = engine
                    onSelectEngine(engine, wasShowingOriginal)
                    if wasShowingOriginal {
                        showOriginal = false
                    }
                } label: {
                    HStack {
                        Text(engine.displayName)
                        Spacer()
                        if engine == selectedEngine {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Color.accentColor)
                Text(selectedEngine.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(Color.primary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { onInteract() })
        }
        .menuStyle(.borderlessButton)
    }
}

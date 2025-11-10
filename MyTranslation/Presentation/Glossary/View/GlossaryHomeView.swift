import SwiftData
import SwiftUI

struct GlossaryHomeView: View {
    @Bindable var viewModel: GlossaryHomeViewModel

    let onCreateTerm: (GlossaryHomeViewModel.PatternSummary?) -> Void
    let onEditTerm: (GlossaryHomeViewModel.TermRow) -> Void
    let onOpenPatternEditor: (GlossaryHomeViewModel.PatternSummary?) -> Void
    let onOpenImport: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @State private var targetForDeletion: GlossaryHomeViewModel.TermRow?
    @State private var duplicationMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            picker
            content
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar { toolbar }
        .task { viewModel.load() }
        .alert("용어 삭제", isPresented: $showDeleteConfirm, presenting: targetForDeletion) { row in
            Button("삭제", role: .destructive) {
                try? viewModel.delete(term: row)
            }
            Button("취소", role: .cancel) { }
        } message: { row in
            Text("\(row.target)을(를) 삭제하시겠습니까?")
        }
        .alert("복제 완료", isPresented: Binding(get: { duplicationMessage != nil }, set: { if !$0 { duplicationMessage = nil } })) {
            Button("확인", role: .cancel) { duplicationMessage = nil }
        } message: {
            Text(duplicationMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("검색 (원문/번역/태그)", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                if !viewModel.searchText.isEmpty {
                    Button { viewModel.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("검색어 지우기")
                }
            }
            .padding(.horizontal)

            if !viewModel.availableTags.isEmpty {
                TagChips(tags: viewModel.availableTags, selection: $viewModel.selectedTagNames)
            }

            patternSelector
            if let pattern = viewModel.pattern(for: viewModel.selectedPatternID), !viewModel.patternGroups.isEmpty {
                HStack {
                    Text("\(pattern.groupLabel) 필터")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("모두 해제") { viewModel.selectedGroupUIDs.removeAll() }
                        .font(.caption)
                        .opacity(viewModel.selectedGroupUIDs.isEmpty ? 0.4 : 1)
                        .disabled(viewModel.selectedGroupUIDs.isEmpty)
                }
                .padding(.horizontal)
                GroupChips(
                    groups: viewModel.patternGroups.map { .init(id: $0.id, name: $0.name, count: $0.componentTerms.count) },
                    selection: $viewModel.selectedGroupUIDs
                )
            }
        }
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var patternSelector: some View {
        HStack(spacing: 12) {
            Menu {
                Button("전체 패턴") { viewModel.setPattern(nil) }
                ForEach(viewModel.patterns) { pattern in
                    Button(pattern.displayName) { viewModel.setPattern(pattern) }
                }
            } label: {
                HStack {
                    Text(viewModel.pattern(for: viewModel.selectedPatternID)?.displayName ?? "전체 패턴")
                    Image(systemName: "chevron.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(uiColor: .systemGray5)))
            }
            .accessibilityLabel("패턴 선택")

            if let pattern = viewModel.pattern(for: viewModel.selectedPatternID) {
                Text(pattern.displayName)
                    .font(.headline)
                    .accessibilityHidden(true)
                Spacer()
                Button("패턴 편집") { onOpenPatternEditor(pattern) }
                Button("패턴으로 용어 생성") { onCreateTerm(pattern) }
            } else {
                Spacer()
                Button("새 용어") { onCreateTerm(nil) }
            }
        }
        .padding(.horizontal)
    }

    private var picker: some View {
        Group {
            if viewModel.pattern(for: viewModel.selectedPatternID) != nil {
                Picker("보기", selection: $viewModel.segment) {
                    ForEach(GlossaryHomeViewModel.Segment.allCases) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, viewModel.pattern(for: viewModel.selectedPatternID) != nil ? 12 : 0)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.segment {
        case .terms:
            termsList
        case .groups:
            groupsList
        }
    }

    private var termsList: some View {
        List {
            ForEach(viewModel.filteredTermRows) { row in
                Button {
                    onEditTerm(row)
                } label: {
                    TermRowView(row: row, pattern: viewModel.pattern(for: viewModel.selectedPatternID))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("편집") { onEditTerm(row) }
                    Button("복제") {
                        if let clone = try? viewModel.duplicate(term: row) {
                            duplicationMessage = "새 키: \(clone.key)"
                        }
                    }
                    Button("삭제", role: .destructive) {
                        targetForDeletion = row
                        showDeleteConfirm = true
                    }
                    if let pattern = row.components.first?.pattern,
                       let summary = viewModel.pattern(for: pattern) {
                        Button("패턴 보기로 이동") { viewModel.setPattern(summary) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { emptyState }
    }

    private var groupsList: some View {
        List(viewModel.filteredPatternGroups) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(group.displayName)
                    .font(.headline)
                Text(group.badgeTargets.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .padding(.vertical, 8)
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.filteredPatternGroups.isEmpty {
                ContentUnavailableView("그룹 없음", systemImage: "person.3", description: Text("선택된 패턴의 그룹이 없습니다."))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.filteredTermRows.isEmpty {
            ContentUnavailableView(
                "결과 없음",
                systemImage: "magnifyingglass",
                description: Text("조건을 조정해 보세요.")
            )
        }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Google 시트 가져오기") { onOpenImport() }
            Button("패턴 추가") { onOpenPatternEditor(nil) }
            if viewModel.pattern(for: viewModel.selectedPatternID) == nil {
                Button("새 용어") { onCreateTerm(nil) }
            }
        }
    }
}

private struct TermRowView: View {
    let row: GlossaryHomeViewModel.TermRow
    let pattern: GlossaryHomeViewModel.PatternSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(primaryText)
                .font(.headline)
            if !row.primarySources.isEmpty {
                Text(row.primarySources.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !row.tags.isEmpty {
                Text(row.tags.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            badges
        }
        .padding(.vertical, 8)
    }

    private var primaryText: String {
        row.displayName(for: pattern)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            if row.isAppellation {
                badge(text: "호칭", color: .blue)
            }
            if row.preMask {
                badge(text: "프리마스크", color: .purple)
            }
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.6), lineWidth: 1)
            )
    }
}

#Preview {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = GlossaryHomeViewModel(context: context)
    Task { @MainActor in await vm.reloadAll() }
    return NavigationStack {
        GlossaryHomeView(viewModel: vm, onCreateTerm: { _ in }, onEditTerm: { _ in }, onOpenPatternEditor: { _ in }, onOpenImport: {})
    }
}

#if DEBUG
enum PreviewData {
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Glossary.SDModel.SDTerm.self,
                 Glossary.SDModel.SDSource.self,
                 Glossary.SDModel.SDComponent.self,
                 Glossary.SDModel.SDGroup.self,
                 Glossary.SDModel.SDComponentGroup.self,
                 Glossary.SDModel.SDTag.self,
                 Glossary.SDModel.SDTermTagLink.self,
                 Glossary.SDModel.SDPattern.self,
                 Glossary.SDModel.SDPatternMeta.self,
                 Glossary.SDModel.SDAppellationMarker.self,
            configurations: config
        )
        seed(into: container.mainContext)
        return container
    }()

    private static func seed(into context: ModelContext) {
        let personPattern = Glossary.SDModel.SDPattern(
            name: "person",
            leftRoles: ["family"],
            rightRoles: ["given"],
            skipPairsIfSameTerm: false,
            sourceTemplates: ["{L}{R}"],
            targetTemplates: ["{L} {R}"],
            sourceJoiners: [" "],
            isAppellation: false,
            preMask: false,
            needPairCheck: false
        )
        context.insert(personPattern)

        let personMeta = Glossary.SDModel.SDPatternMeta(
            name: "person",
            displayName: "인물",
            roles: ["family", "given"],
            grouping: .optional,
            groupLabel: "호칭",
            defaultProhibitStandalone: false,
            defaultIsAppellation: false,
            defaultPreMask: false
        )
        context.insert(personMeta)

        let group = Glossary.SDModel.SDGroup(pattern: "person", name: "주요 인물")
        context.insert(group)

        let family = Glossary.SDModel.SDTerm(key: "person-family", target: "홍")
        let familySource = Glossary.SDModel.SDSource(text: "홍", prohibitStandalone: false, term: family)
        family.sources = [familySource]
        context.insert(familySource)
        context.insert(family)

        let given = Glossary.SDModel.SDTerm(key: "person-given", target: "길동")
        let givenSource = Glossary.SDModel.SDSource(text: "길동", prohibitStandalone: false, term: given)
        given.sources = [givenSource]
        context.insert(givenSource)
        context.insert(given)

        let familyComponent = Glossary.SDModel.SDComponent(pattern: "person", roles: ["family"], srcTplIdx: 0, tgtTplIdx: 0, term: family)
        let givenComponent = Glossary.SDModel.SDComponent(pattern: "person", roles: ["given"], srcTplIdx: 0, tgtTplIdx: 0, term: given)
        context.insert(familyComponent)
        context.insert(givenComponent)
        family.components = [familyComponent]
        given.components = [givenComponent]

        let familyBridge = Glossary.SDModel.SDComponentGroup(component: familyComponent, group: group)
        let givenBridge = Glossary.SDModel.SDComponentGroup(component: givenComponent, group: group)
        context.insert(familyBridge)
        context.insert(givenBridge)
        familyComponent.groupLinks = [familyBridge]
        givenComponent.groupLinks = [givenBridge]

        let tag = Glossary.SDModel.SDTag(name: "주요")
        context.insert(tag)
        let familyTagLink = Glossary.SDModel.SDTermTagLink(term: family, tag: tag)
        let givenTagLink = Glossary.SDModel.SDTermTagLink(term: given, tag: tag)
        context.insert(familyTagLink)
        context.insert(givenTagLink)
        family.termTagLinks = [familyTagLink]
        given.termTagLinks = [givenTagLink]

        try? context.save()
    }
}
#endif

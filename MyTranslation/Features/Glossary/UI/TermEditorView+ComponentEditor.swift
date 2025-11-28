import SwiftUI

extension TermEditorView {
    @ViewBuilder
    var componentEditor: some View {
        if viewModel.canEditComponents {
            Section("패턴 연결") {
                if viewModel.componentDrafts.isEmpty {
                    Text("패턴을 선택해 새 연결을 추가하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach($viewModel.componentDrafts) { component in
                    componentCard(for: component)
                        .padding(.vertical, 4)
                }
                Button {
                    viewModel.addComponentDraft()
                } label: {
                    Label("패턴 연결 추가", systemImage: "plus")
                }
            }
        }
    }

    func componentCard(for component: Binding<TermEditorViewModel.ComponentDraft>) -> some View {
        let patternSelection = Binding<String?>(
            get: { component.patternID.wrappedValue },
            set: { newValue in
                component.patternID.wrappedValue = newValue
                viewModel.didSelectPattern(for: component.wrappedValue.id, patternID: newValue)
            }
        )
        let patternID = component.patternID.wrappedValue
        let hasPattern = viewModel.patternOption(for: patternID) != nil
        return VStack(alignment: .leading, spacing: 12) {
            Picker("패턴", selection: patternSelection) {
                Text("패턴 선택").tag(String?.none)
                if let patternID,
                   !viewModel.sortedPatternOptions.contains(where: { $0.id == patternID }) {
                    Text(patternID).tag(Optional(patternID))
                }
                ForEach(viewModel.sortedPatternOptions) { option in
                    Text(option.displayName).tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)

            if hasPattern {
                let roles = viewModel.availableRoles(for: patternID)
                if !roles.isEmpty {
                    let roleSelection = Binding<String>(
                        get: { component.roleName.wrappedValue },
                        set: { component.roleName.wrappedValue = $0 }
                    )
                    Picker("역할", selection: roleSelection) {
                        Text("역할 없음").tag("")
                        ForEach(roles, id: \.self) { role in
                            Text(role).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Text("이 패턴에는 지정할 역할 슬롯이 없습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                let grouping = viewModel.grouping(for: patternID)
                if grouping != .none {
                    GroupSelectionField(
                        label: viewModel.groupLabel(for: patternID),
                        grouping: grouping,
                        options: viewModel.availableGroups(for: patternID),
                        selectedGroupID: component.selectedGroupUID,
                        customName: component.customGroupName
                    )
                }

                templatePicker(
                    title: "원문 템플릿",
                    templates: viewModel.sourceTemplates(for: patternID),
                    selection: component.srcTemplateIndex
                )
                templatePicker(
                    title: "번역 템플릿",
                    templates: viewModel.targetTemplates(for: patternID),
                    selection: component.tgtTemplateIndex
                )
            } else {
                Text("패턴을 선택하면 역할, 그룹, 템플릿을 설정할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                viewModel.removeComponentDraft(id: component.wrappedValue.id)
            } label: {
                Label("연결 삭제", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    func templatePicker(title: String, templates: [String], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if templates.isEmpty {
                Text("사용 가능한 템플릿이 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker(title, selection: selection) {
                    ForEach(Array(templates.enumerated()), id: \.offset) { item in
                        Text("\(item.offset + 1): \(item.element)")
                            .lineLimit(2)
                            .tag(item.offset)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    var activatorChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(viewModel.generalDraft.activatedByArray, id: \.self) { termKey in
                HStack(spacing: 4) {
                    Text(viewModel.termTarget(for: termKey) ?? termKey)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                    Button {
                        viewModel.removeActivatorTerm(key: termKey)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
                .background(.quaternary)
                .cornerRadius(12)
            }
        }
        .padding(.top, 4)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let position = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize
        var positions: [CGPoint]

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var positions: [CGPoint] = []
            var lineHeight: CGFloat = 0
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                positions.append(CGPoint(x: currentX, y: currentY))
                currentX += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }

            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
            self.positions = positions
        }
    }
}

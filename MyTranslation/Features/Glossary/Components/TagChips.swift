import SwiftUI

struct TagChips: View {
    let tags: [String]
    @Binding var selection: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    SelectableChip(title: tag, isSelected: selection.contains(tag)) {
                        if selection.contains(tag) {
                            selection.remove(tag)
                        } else {
                            selection.insert(tag)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .accessibilityElement()
        .accessibilityLabel("태그 필터")
    }
}

struct GroupChips: View {
    struct Group: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
    }

    let groups: [Group]
    @Binding var selection: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    SelectableChip(title: "\(group.name) (\(group.count))", isSelected: selection.contains(group.id)) {
                        if selection.contains(group.id) {
                            selection.remove(group.id)
                        } else {
                            selection.insert(group.id)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .accessibilityElement()
        .accessibilityLabel("그룹 필터")
    }
}

private struct SelectableChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(isSelected ? "선택됨" : "미선택")")
    }
}

#Preview("TagChips") {
    StatefulPreviewWrapper(Set<String>()) { binding in
        TagChips(tags: ["인물", "초능력", "호칭"], selection: binding)
    }
    .padding()
}

#Preview("GroupChips") {
    StatefulPreviewWrapper(Set<String>()) { binding in
        GroupChips(groups: [.init(id: "A", name: "A", count: 3), .init(id: "B", name: "B", count: 1)], selection: binding)
    }
    .padding()
}

#if DEBUG
struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initialValue: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initialValue)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
#endif

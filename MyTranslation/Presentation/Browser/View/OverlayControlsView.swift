// File: OverlayControlsView.swift
import SwiftUI

struct OverlayControlsView: View {
    @EnvironmentObject var app: AppContainer
    @Binding var showOriginal: Bool
    @Binding var engineBadgeEnabled: Bool
    @Binding var reviewOnlyFilter: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            Toggle("AI 사용", isOn: $app.settings.useFM)
            Toggle("원문보기", isOn: $showOriginal)
            Toggle("엔진뱃지", isOn: $engineBadgeEnabled)
            Toggle("[재검토]만", isOn: $reviewOnlyFilter)
        }
        .toggleStyle(.switch)
        .padding(8)
    }
}

// File: SettingsView.swift
import SwiftUI

struct SettingsView: View { // NEW
    @AppStorage("preferredEngine") private var preferredEngineRawValue: String = EngineTag.afm.rawValue
    @AppStorage("useFM") private var useFM: Bool = true

    private var preferredEngine: Binding<EngineTag> {
        Binding(
            get: { EngineTag(rawValue: preferredEngineRawValue) ?? .afm },
            set: { preferredEngineRawValue = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("번역 설정") {
                    Picker("기본 엔진", selection: preferredEngine) {
                        ForEach(EngineTag.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }

                    Toggle("온디바이스 FM 사용", isOn: $useFM)
                }
            }
            .navigationTitle("설정")
        }
    }
}

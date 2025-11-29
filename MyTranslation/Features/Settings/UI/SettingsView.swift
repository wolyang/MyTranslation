// File: SettingsView.swift
import SwiftUI

struct SettingsView: View { // NEW
    @AppStorage("preferredEngine") private var preferredEngineRawValue: String = EngineTag.afm.rawValue
    @AppStorage("useFM") private var useFM: Bool = true
    @AppStorage("recentURLLimit") private var recentURLLimit: Int = 8

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

                Section("브라우저") {
                    Stepper(value: $recentURLLimit, in: 1...20) {
                        Text("방문 기록 보관 개수: \(recentURLLimit)개")
                    }
                }
            }
            .navigationTitle("설정")
        }
    }
}

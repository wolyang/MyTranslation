// File: URLBarView.swift
import SwiftUI

struct URLBarView: View {
    @Binding var urlString: String
    var onGo: (String) -> Void
    var body: some View {
        HStack {
            TextField("https://…", text: $urlString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .onSubmit { onGo(urlString) }
            Button("이동") { onGo(urlString) }
        }
        .padding(8)
    }
}

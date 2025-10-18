import SwiftUI
import WebKit

@MainActor
struct WebContainerView: UIViewRepresentable {
    let request: URLRequest?
    var onAttach: ((WKWebView) -> Void)? = nil
    var onDidFinish: ((WKWebView, URL) -> Void)? = nil
    var onSelectSegment: ((String, CGRect) -> Void)? = nil
    var onNavigate: (() -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "selection")
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.install(on: webView)
        onAttach?(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let req = request else { return }
        // 동일 URL 반복 로드 방지 (리다이렉트가 잦다면 커스텀 비교 로직 고려)
        if uiView.url == nil || uiView.url?.absoluteString != req.url?.absoluteString {
            uiView.load(req)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let parent: WebContainerView
        var bridge: SelectionBridge?
        private weak var webView: WKWebView?
        private var lastMarkRunKey: String?
        
        init(parent: WebContainerView) { self.parent = parent }
        
        
        func install(on webView: WKWebView) {
            self.webView = webView
            webView.isInspectable = true
            self.bridge = SelectionBridge(webView: webView)

            // 기존 bridge.onSelect 제거됨
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "selection")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "mtconsole")
            webView.configuration.userContentController.add(self, name: "selection")
            webView.configuration.userContentController.add(self, name: "mtconsole")
        }

        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            print("[UCC] didReceive message")
            
            switch msg.name {
            case "mtconsole":
                if let m = msg.body as? [String: Any],
                               let level = m["level"] as? String,
                               let args = m["args"] as? [String] {
                                print("[JS.\(level)]", args.joined(separator: " "))
                            }
            case "selection":
                guard let segId = msg.body as? String,
                      let web = self.webView else {
                    print("[SEL] invalid body:", type(of: msg.body))
                    return
                }

                // rect 조회 후 SwiftUI 계층으로 전달
                Task { [weak self] in
                    guard let self else { return }
                    let exec = WKWebViewScriptAdapter(webView: web)
                    struct R: Decodable { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }
                    let rect: CGRect
                    if let rectJSON: String = try? await exec.runJS(#"window.MT_GET_RECT(\#(String(reflecting: segId)))"#),
                       let data = rectJSON.data(using: .utf8),
                       let r = try? JSONDecoder().decode(R.self, from: data)
                    {
                        rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                    } else {
                        rect = .zero
                    }
                    await MainActor.run {
                        self.parent.onSelectSegment?(segId, rect)
                    }
                }
            default:
                break
            }

        }

        func markSegments(_ pairs: [(id: String, text: String)]) async {
            // 같은 페이지(=URL)에서 같은 runKey로 두 번 이상 호출 방지
                    let urlKey = webView?.url?.absoluteString ?? UUID().uuidString
                    let runKey = urlKey + "|count=\(pairs.count)"
                    if lastMarkRunKey == runKey { return }
                    lastMarkRunKey = runKey

                    // 로그
                    let totalChars = pairs.reduce(0) { $0 + $1.text.count }
                    print("[MARK] calling MT_MARK_SEGMENTS_ALL list=\(pairs.count) chars=\(totalChars) url=\(urlKey)")

            await bridge?.mark(segments: pairs)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            parent.onNavigate?()

            // ❗️요청별 once 보장: 전역 플래그를 쓰지 말고, 로컬 클로저로 가드
            var called = false
            let decideOnce: (WKNavigationActionPolicy) -> Void = { policy in
                guard !called else { return }
                called = true
                decisionHandler(policy)
            }

            // 외부 스킴 처리 예: 호출 후 반드시 return
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["tel", "mailto", "maps", "itms-apps"].contains(scheme) {
                UIApplication.shared.open(url)
                decideOnce(.cancel)
                return
            }

            // (비동기 판단이 필요하면 여기서 .cancel 후 별도 로드를 트리거하세요.
            //  또는 판단이 끝난 즉시 decideOnce(.allow) — 어쨌든 한번만 호출)

            decideOnce(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                parent.onDidFinish?(webView, url)
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onNavigate?()
        }
    }
}

import SwiftUI
import WebKit
import UIKit

@MainActor
struct WebContainerView: UIViewRepresentable {
    let request: URLRequest?
    let requestID: UUID
    var onAttach: ((WKWebView) -> Void)? = nil
    var onDidFinish: ((WKWebView, URL) -> Void)? = nil
    var onSelectSegment: ((String, CGRect) -> Void)? = nil
    var onNavigate: (() -> Void)? = nil
    var onUserInteraction: (() -> Void)? = nil

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

        let currentURL = uiView.url?.absoluteString ?? "nil"
        let requestURL = req.url?.absoluteString ?? "nil"
        let alreadyProcessed = context.coordinator.lastProcessedRequestID == requestID

        print("[WebContainer] updateUIView current=\(currentURL) req=\(requestURL) reqID=\(requestID) processed=\(alreadyProcessed)")

        // 이미 처리한 요청이면 건너뜀
        if alreadyProcessed {
            print("[WebContainer] → skip (already processed)")
            return
        }

        // URL이 다르면 새 요청 로드
        if uiView.url == nil || uiView.url?.absoluteString != req.url?.absoluteString {
            print("[WebContainer] → load(req)")
            uiView.load(req)
            context.coordinator.lastProcessedRequestID = requestID
        } else if req.cachePolicy == .reloadIgnoringLocalCacheData {
            // 동일 URL이지만 명시적으로 캐시 무시 요청이면 reload
            print("[WebContainer] → reload()")
            uiView.reload()
            context.coordinator.lastProcessedRequestID = requestID
        } else {
            print("[WebContainer] → skip (same URL + normal cache)")
            context.coordinator.lastProcessedRequestID = requestID
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        private let parent: WebContainerView
        var bridge: SelectionBridge?
        private weak var webView: WKWebView?
        private var markedSegmentIDs: Set<String> = []
        private weak var interactionTap: UITapGestureRecognizer?
        private var hasAttachedPanHandler: Bool = false
        var lastProcessedRequestID: UUID? = nil

        init(parent: WebContainerView) { self.parent = parent }
        
        
        func install(on webView: WKWebView) {
            if let current = self.webView, current !== webView {
                current.scrollView.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollPan(_:)))
                if let tap = interactionTap {
                    current.removeGestureRecognizer(tap)
                }
                hasAttachedPanHandler = false
                interactionTap = nil
            }

            self.webView = webView
            webView.isInspectable = true
            self.bridge = SelectionBridge(webView: webView)

            // 기존 bridge.onSelect 제거됨
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "selection")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "mtconsole")
            webView.configuration.userContentController.add(self, name: "selection")
            webView.configuration.userContentController.add(self, name: "mtconsole")
            attachInteractionHandlers(to: webView)
        }

        private func attachInteractionHandlers(to webView: WKWebView) {
            if hasAttachedPanHandler == false {
                webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollPan(_:)))
                hasAttachedPanHandler = true
            }
            if interactionTap == nil || interactionTap?.view !== webView {
                if let existingTap = interactionTap, existingTap.view !== webView {
                    existingTap.view?.removeGestureRecognizer(existingTap)
                }
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleContentTap(_:)))
                tap.cancelsTouchesInView = false
                tap.delegate = self
                webView.addGestureRecognizer(tap)
                interactionTap = tap
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
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
                    let rawRect: CGRect
                    if let rectJSON: String = try? await exec.runJS(#"window.MT_GET_RECT(\#(String(reflecting: segId)))"#),
                       let data = rectJSON.data(using: .utf8),
                       let r = try? JSONDecoder().decode(R.self, from: data)
                    {
                        rawRect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                    } else {
                        rawRect = .zero
                    }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let convertedRect = self.viewportRect(from: rawRect, in: web)
                        self.parent.onSelectSegment?(segId, convertedRect)
                    }
                }
            default:
                break
            }

        }

        private func viewportRect(from rect: CGRect, in webView: WKWebView) -> CGRect {
            let scrollView = webView.scrollView
            let scale = scrollView.zoomScale > 0 ? scrollView.zoomScale : 1
            let inset = scrollView.adjustedContentInset
            var scaled = CGRect(
                x: rect.origin.x * scale,
                y: rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
            scaled.origin.x += inset.left
            scaled.origin.y += inset.top
            return scaled
        }

        func resetMarks() {
            markedSegmentIDs.removeAll()
        }

        func markSegments(_ segments: [Segment]) async {
            guard segments.isEmpty == false else { return }
            let fresh = segments.filter { segment in
                guard markedSegmentIDs.contains(segment.id) == false else { return false }
                return segment.domRange != nil
            }
            guard fresh.isEmpty == false else { return }

            let urlKey = webView?.url?.absoluteString ?? UUID().uuidString
            let totalChars = fresh.reduce(0) { $0 + $1.originalText.count }
            print("[MARK] calling MT_MARK_SEGMENTS_ALL list=\(fresh.count) chars=\(totalChars) url=\(urlKey)")

            fresh.forEach { markedSegmentIDs.insert($0.id) }
            await bridge?.mark(segments: fresh)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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

        @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                parent.onUserInteraction?()
            }
        }

        @objc private func handleContentTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended {
                parent.onUserInteraction?()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

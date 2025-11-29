// File: OverlayRenderer.swift
import Foundation
import WebKit

protocol OverlayRenderer {
    func attachOverlay(to webView: WKWebView)
    func render(results: [TranslationResult], in webView: WKWebView)
    func toggleOriginal(_ showOriginal: Bool, in webView: WKWebView)
    func replaceInPage(pairs: [(original: String, translated: String)], in webView: WKWebView)
    func restoreOriginalPage(in webView: WKWebView)
}

final class DefaultOverlayRenderer: OverlayRenderer {
    func attachOverlay(to webView: WKWebView) {
//        panel.style.background='rgba(255,255,255,0.86)';
//        panel.style.backdropFilter='blur(6px)';
        // 임시 제거
        let js = """
        (function(){
          if (document.getElementById('afm-overlay-root')) return 'exists';
          var root = document.createElement('div');
          root.id='afm-overlay-root';
          root.style.position='fixed';
          root.style.inset='0';
          root.style.pointerEvents='none';
          root.style.zIndex='2147483647';
          root.style.display='flex';
          root.style.justifyContent='center';
          root.style.alignItems='flex-start';
          var panel = document.createElement('div');
          panel.id='afm-overlay-panel';
          panel.style.maxWidth='min(960px, 92vw)';
          panel.style.margin='16px auto';
          panel.style.background='rgba(255,255,255,0.96)';
          panel.style.borderRadius='12px';
          panel.style.boxShadow='0 10px 30px rgba(0,0,0,0.25)';
          panel.style.padding='16px';
          panel.style.font='-apple-system-body';
          panel.style.lineHeight='1.5';
          panel.style.color='#111';
          panel.style.pointerEvents='auto';     // 패널은 클릭/스크롤 허용(복사 등 UX 개선)
          root.appendChild(panel);
          (document.body || document.documentElement).appendChild(root); // body 우선
          return 'attached';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func render(results: [TranslationResult], in webView: WKWebView) {
        let paras = results.map { r in
            let badge = r.engine.rawValue.uppercased()
            return "<p style=\\\"margin:0 0 8px\\\"><span style=\\\"opacity:.6\\\">\(badge)</span> \(r.text.htmlEscaped)</p>"
        }.joined()

        // ✅ JS literal로 안전하게 인젝션 (JSON 문자열 인코딩 이용)
        let htmlLiteral = DefaultOverlayRenderer.jsQuoted(paras)

        let js = """
        (function(){
          var panel = document.getElementById('afm-overlay-panel');
          if(!panel){return 'no_panel'}
          var html = \(htmlLiteral);
          panel.innerHTML = html;
          return 'ok';
        })();
        """

        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("Overlay JS error:", error.localizedDescription)
            } else {
                print("Overlay render status:", result ?? "nil")
            }
        }
    }

    func toggleOriginal(_ showOriginal: Bool, in webView: WKWebView) {
        // showOriginal == true → 패널 완전 비활성(클릭 통과)
        let js = """
        (function(){
          var root = document.getElementById('afm-overlay-root');
          var panel = document.getElementById('afm-overlay-panel');
          if(!root || !panel){return 'no_root_or_panel'}
          
            panel.style.display = 'none';
            panel.style.pointerEvents = 'none';
            root.style.opacity = '0';
          
          return 'ok';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    func replaceInPage(pairs: [(original: String, translated: String)], in webView: WKWebView) {
        let payload: [[String:String]] = pairs.map { ["o": $0.original, "t": $0.translated] }
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let json = String(data: data, encoding: .utf8)
        else { return }

        let js = """
        (function(){
          const pairs = \(json);
          if (!Array.isArray(pairs)) return 'bad_pairs';

          const candidates = Array.from(document.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,span,div'));
          let replacedCount = 0;

          for (const el of candidates) {
            if (el.dataset.afmReplaced === '1') continue;
            const raw = (el.innerText || '').trim();
            if (!raw) continue;

            const hit = pairs.find(x => (x.o || '').trim() === raw);
            if (hit) {
              el.dataset.afmReplaced = '1';
              el.dataset.afmOriginal = raw;
              el.textContent = hit.t;
              replacedCount++;
            }
          }
          return 'replaced:' + replacedCount;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func restoreOriginalPage(in webView: WKWebView) {
        let js = """
        (function(){
          const changed = document.querySelectorAll('[data-afm-replaced="1"][data-afm-original]');
          let n=0;
          changed.forEach(el => {
            el.textContent = el.dataset.afmOriginal;
            el.removeAttribute('data-afm-original');
            el.removeAttribute('data-afm-replaced');
            n++;
          });
          return 'restored:' + n;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

private extension String { var htmlEscaped: String { self
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&#39;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
}}

private extension DefaultOverlayRenderer {
    /// Swift String을 JS의 안전한 문자열 리터럴로 변환 (JSON을 이용)
    static func jsQuoted(_ s: String) -> String {
        // ["..."] 형태로 직렬화된 문자열 배열을 만들어 첫/끝 대괄호를 제거
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           var quotedArray = String(data: data, encoding: .utf8) {
            // quotedArray는 예: ["<p>..</p>..."]
            // 앞의 '['와 뒤의 ']' 제거
            quotedArray.removeFirst()
            quotedArray.removeLast()
            return quotedArray
        }
        // 실패 시 가장 보수적으로 빈 문자열 리터럴
        return "\"\""
    }
}

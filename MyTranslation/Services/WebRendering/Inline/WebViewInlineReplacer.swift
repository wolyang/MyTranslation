//
//  WebViewInlineReplacer.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

final class WebViewInlineReplacer: InlineReplacer {
    public func setPairs(_ pairs: [(original: String, translated: String)], using exec: WebViewScriptExecutor) {
        let payload = pairs.map { ["o": $0.original, "t": $0.translated] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = """
        (function(){
          const P = \(json);
          const norm = s => (s||'').replace(/\\s+/g,' ').trim();
          const map = new Map(); for (const p of P) map.set(norm(p.o), p.t);

          if (!window.__afmInline) window.__afmInline = {};
          const S = window.__afmInline;
          S.norm = norm;
          S.map = map;

          // 스킵: script/style/textarea/contenteditable 내부는 제외
          S.shouldSkipNode = (node) => {
            if (!node || node.nodeType !== Node.TEXT_NODE) return true;
            const txt = node.nodeValue;
            if (!txt || !txt.trim()) return true;
            const el = node.parentElement;
            if (!el) return true;
            if (el.closest('script,style,textarea,[contenteditable]')) return true;
            return false;
          };

          S.tryReplaceTextNode = (node) => {
            if (S.shouldSkipNode(node)) return false;
            if (node.__afmApplied) return false;
            const raw = S.norm(node.nodeValue);
            const t = S.map.get(raw);
            if (t) {
              node.__afmOriginal = node.nodeValue;
              node.nodeValue = t;   // 텍스트만 교체 → 이벤트/구조 보존
              node.__afmApplied = true;
              return true;
            }
            return false;
          };

          S.applyAll = (root) => {
            const r = root || document.body || document.documentElement;
            const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
            let n, count = 0;
            while ((n = walker.nextNode())) { if (S.tryReplaceTextNode(n)) count++; }
            return count;
          };

          S.restoreAll = (root) => {
            const r = root || document.body || document.documentElement;
            const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
            let n, count = 0;
            while ((n = walker.nextNode())) {
              if (n.__afmApplied && typeof n.__afmOriginal === 'string') {
                n.nodeValue = n.__afmOriginal;
                n.__afmOriginal = undefined;
                n.__afmApplied = undefined;
                count++;
              }
            }
            return count;
          };

          // micro-throttle (attributes 변동 다발 시 병합)
          S._pending = false;
          S._scheduleApply = (root) => {
            if (S._pending) return;
            S._pending = true;
            (window.requestAnimationFrame || setTimeout)(() => {
              S._pending = false;
              S.applyAll(root);
            }, 16);
          };

          S.enableObserver = () => {
            if (S.observer) return 'exists';
            S.observer = new MutationObserver(muts => {
              for (const m of muts) {
                if (m.type === 'childList') {
                  m.addedNodes && m.addedNodes.forEach(node => {
                    if (node.nodeType === Node.TEXT_NODE) { S.tryReplaceTextNode(node); }
                    else if (node.nodeType === Node.ELEMENT_NODE) { S.applyAll(node); }
                  });
                } else if (m.type === 'characterData') {
                  if (m.target && m.target.nodeType === Node.TEXT_NODE) S.tryReplaceTextNode(m.target);
                } else if (m.type === 'attributes') {
                  // class/open/hidden/style/aria-expanded 변동 시 해당 서브트리에 재적용
                  const el = m.target;
                  if (el && el.nodeType === Node.ELEMENT_NODE) S._scheduleApply(el);
                }
              }
            });
            const root = document.body || document.documentElement;
            S.observer.observe(root, {
              subtree: true,
              childList: true,
              characterData: true,
              attributes: true,
              attributeFilter: ['class','open','hidden','style','aria-expanded']
            });
            return 'enabled';
          };

          S.disableObserver = () => {
            if (S.observer) { S.observer.disconnect(); S.observer = null; return 'disabled'; }
            return 'noop';
          };

          return 'pairs_set:' + S.map.size;
        })();
        """
        Task {
            _ = try? await exec.runJS(js)
        }
    }

    func apply(using exec: WebViewScriptExecutor, observe: Bool) {
        let js = """
        (function(){
          const S = window.__afmInline;
          if (!S || !S.map) return 'no_state';
          const c = S.applyAll(document.body || document.documentElement);
          if (\(observe ? "true" : "false")) S.enableObserver();
          return 'applied:' + c;
        })();
        """
        Task { _ = try? await exec.runJS(js) }
    }

    func restore(using exec: WebViewScriptExecutor) {
        let js = """
        (function(){
          const S = window.__afmInline;
          if (!S) return 'no_state';
          S.disableObserver && S.disableObserver();
          const c = S.restoreAll(document.body || document.documentElement);
          return 'restored:' + c;
        })();
        """
        Task { _ = try? await exec.runJS(js) }
    }
}

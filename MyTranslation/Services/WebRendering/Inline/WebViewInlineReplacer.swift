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

            // 기존 로직은 __afmApplied 플래그가 true인 노드를 무조건 건너뛰어
            // 번역 테이블(map)이 바뀌어도 새 텍스트로 갱신되지 않았다.
            // 저장해 둔 원문(__afmOriginal)을 기준으로 다시 매핑해 항상 최신 치환을 적용한다.
            const hadApplied = !!node.__afmApplied;
            const hasStoredOriginal = typeof node.__afmOriginal === 'string';
            const original = hasStoredOriginal ? node.__afmOriginal : node.nodeValue;
            const raw = S.norm(original);
            const translated = S.map.get(raw);

            if (translated) {
              if (!hadApplied) {
                node.__afmOriginal = node.nodeValue;
              } else if (!hasStoredOriginal) {
                node.__afmOriginal = original;
              }

              const changed = node.nodeValue !== translated;
              if (changed) {
                node.nodeValue = translated;   // 텍스트만 교체 → 이벤트/구조 보존
              }
              node.__afmApplied = true;
              // true를 반환하면 실제 텍스트가 새 번역으로 교체되었거나 이번 호출에서 최초로 번역 플래그를 세운 경우다.
              return changed || !hadApplied;
            }

            if (hadApplied && hasStoredOriginal) {
              const changed = node.nodeValue !== node.__afmOriginal;
              if (changed) {
                node.nodeValue = node.__afmOriginal;
              }
              node.__afmOriginal = undefined;
              node.__afmApplied = undefined;
              // true는 이전 번역을 걷어내고 원문으로 되돌렸다는 뜻이다.
              return changed;
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

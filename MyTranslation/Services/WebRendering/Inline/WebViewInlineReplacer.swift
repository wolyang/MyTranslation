//  WebViewInlineReplacer.swift
//  MyTranslation
//
//  Updated for streaming payload contract.

import Foundation

/// NOTE: BrowserViewModel과 동일한 TranslationStreamPayload 계약을 사용합니다. 변경 시 두 곳을 함께 업데이트하세요.
final class WebViewInlineReplacer: InlineReplacer {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    func setPairs(
        _ payloads: [TranslationStreamPayload],
        using exec: WebViewScriptExecutor,
        observer: InlineObserverBehavior
    ) {
        guard let data = try? encoder.encode(payloads),
              let json = String(data: data, encoding: .utf8) else { return }
        let behavior = Self.observerToken(for: observer)
        let script = Self.bootstrapPrefix
            + "return __afmInline.setAll(\(json), { observer: '\(behavior)' });"
            + Self.bootstrapSuffix
        Task { _ = try? await exec.runJS(script) }
    }

    func upsert(
        payload: TranslationStreamPayload,
        using exec: WebViewScriptExecutor,
        applyImmediately: Bool,
        highlight: Bool
    ) {
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = Self.bootstrapPrefix
            + "return __afmInline.upsertPair(\(json), { immediate: \(applyImmediately ? "true" : "false"), schedule: true, highlight: \(highlight ? "true" : "false") });"
            + Self.bootstrapSuffix
        Task { _ = try? await exec.runJS(script) }
    }

    func apply(using exec: WebViewScriptExecutor, observe: Bool) {
        let script = Self.bootstrapPrefix
            + "if (\(observe ? "true" : "false")) { __afmInline.enableObserver(); } else { __afmInline.disableObserver(); } return __afmInline.applyAll();"
            + Self.bootstrapSuffix
        Task { _ = try? await exec.runJS(script) }
    }

    func restore(using exec: WebViewScriptExecutor) {
        let script = Self.bootstrapPrefix
            + "__afmInline.disableObserver(); return __afmInline.restoreAll();"
            + Self.bootstrapSuffix
        Task { _ = try? await exec.runJS(script) }
    }
}

private extension WebViewInlineReplacer {
    static func observerToken(for behavior: InlineObserverBehavior) -> String {
        switch behavior {
        case .keep: return "keep"
        case .restart: return "restart"
        case .disable: return "disable"
        }
    }

    static var bootstrapPrefix: String {
        """
        (function(){
          if (!window.__afmInline || window.__afmInline.__contractVersion !== 1) {
            const S = {};
            S.__contractVersion = 1;
            S.store = new Map();
            S.pending = false;
            S.highlightDuration = 800;

            S._isValidPayload = function(payload) {
              return payload && typeof payload.segmentID === 'string' && typeof payload.originalText === 'string';
            };

            S._ensureStyle = function() {
              if (S._styleInjected) return;
              const style = document.createElement('style');
              style.setAttribute('data-afm-inline-style', '1');
              style.textContent = '[data-seg-id].mt-inline-updated{outline:2px solid rgba(0,145,255,0.45); background-color: rgba(0,145,255,0.12);}';
              try { document.head && document.head.appendChild(style); } catch(e) {}
              S._styleInjected = true;
            };

            S._queryNodes = function(segmentID, root) {
              const base = root || document;
              if (!base) return [];
              let nodes = [];
              try {
                if (base.querySelectorAll) {
                  nodes = Array.from(base.querySelectorAll('[data-seg-id="' + segmentID.replace(/"/g,'\\"') + '"]'));
                }
              } catch(e) {
                nodes = [];
              }
              if (base !== document && base.getAttribute && base.getAttribute('data-seg-id') === segmentID) {
                nodes.push(base);
              }
              return nodes;
            };

            S._restoreNode = function(node, fallback) {
              if (typeof node.__afmOriginalText === 'string') {
                if (node.textContent !== node.__afmOriginalText) {
                  node.textContent = node.__afmOriginalText;
                }
              } else if (typeof fallback === 'string') {
                if (node.textContent !== fallback) {
                  node.textContent = fallback;
                }
              }
              node.__afmApplied = false;
              node.removeAttribute && node.removeAttribute('data-afm-engine');
              node.removeAttribute && node.removeAttribute('data-afm-seq');
              node.classList && node.classList.remove('mt-inline-updated');
            };

            S._applyToNode = function(node, payload, highlight) {
              if (!node) return false;
              const original = typeof node.__afmOriginalText === 'string' ? node.__afmOriginalText : node.textContent;
              if (typeof node.__afmOriginalText !== 'string') {
                node.__afmOriginalText = original;
              }
              const translated = typeof payload.translatedText === 'string' ? payload.translatedText : null;
              if (translated && translated.length) {
                if (node.textContent !== translated) {
                  node.textContent = translated;
                }
                node.__afmApplied = true;
                node.setAttribute && node.setAttribute('data-afm-engine', payload.engineID || '');
                node.setAttribute && node.setAttribute('data-afm-seq', String(payload.sequence || 0));
                if (highlight && node.classList) {
                  S._ensureStyle();
                  node.classList.add('mt-inline-updated');
                  setTimeout(() => { try { node.classList.remove('mt-inline-updated'); } catch(e) {} }, S.highlightDuration);
                }
                return true;
              }

              if (node.__afmApplied) {
                S._restoreNode(node, payload.originalText);
                return true;
              }
              return false;
            };

            S.applyPayload = function(payload, opts) {
              if (!S._isValidPayload(payload)) return 0;
              const highlight = opts && opts.highlight === true;
              const root = opts && opts.root ? opts.root : null;
              const nodes = S._queryNodes(payload.segmentID, root);
              let applied = 0;
              if (!nodes.length) return applied;
              for (let i = 0; i < nodes.length; i++) {
                if (S._applyToNode(nodes[i], payload, highlight)) {
                  applied++;
                }
              }
              return applied;
            };

            S.applyAll = function(root) {
              const base = root || null;
              let sum = 0;
              S.store.forEach(payload => {
                sum += S.applyPayload(payload, { highlight: false, root: base });
              });
              return sum;
            };

            S.restoreAll = function(root) {
              const base = root || document;
              if (!base) return 0;
              let nodes = [];
              try {
                nodes = Array.from(base.querySelectorAll('[data-seg-id]'));
              } catch(e) {
                nodes = [];
              }
              let count = 0;
              for (let i = 0; i < nodes.length; i++) {
                const node = nodes[i];
                if (node && node.__afmApplied) {
                  S._restoreNode(node, null);
                  count++;
                }
              }
              return count;
            };

            S.scheduleApply = function(root) {
              if (S.pending) return 'pending';
              S.pending = true;
              (window.requestAnimationFrame || setTimeout)(() => {
                try { S.applyAll(root || null); } catch(e) {}
                S.pending = false;
              }, 16);
              return 'scheduled';
            };

            S.enableObserver = function() {
              if (S.observer) return 'exists';
              const target = document.body || document.documentElement;
              if (!target) return 'no_root';
              S.observer = new MutationObserver(mutations => {
                for (let i = 0; i < mutations.length; i++) {
                  const mutation = mutations[i];
                  if (mutation.type === 'childList') {
                    mutation.addedNodes && mutation.addedNodes.forEach(node => {
                      if (!node) return;
                      if (node.nodeType === Node.ELEMENT_NODE) {
                        S.applyAll(node);
                      } else if (node.nodeType === Node.TEXT_NODE) {
                        const host = node.parentElement && node.parentElement.closest ? node.parentElement.closest('[data-seg-id]') : null;
                        if (host) {
                          const seg = host.getAttribute('data-seg-id');
                          const payload = seg && S.store.get(seg);
                          if (payload) S.applyPayload(payload, { highlight: false, root: host });
                        }
                      }
                    });
                  } else if (mutation.type === 'characterData') {
                    const host = mutation.target && mutation.target.parentElement && mutation.target.parentElement.closest ? mutation.target.parentElement.closest('[data-seg-id]') : null;
                    if (host) {
                      const seg = host.getAttribute('data-seg-id');
                      const payload = seg && S.store.get(seg);
                      if (payload) S.scheduleApply(host);
                    }
                  }
                }
              });
              S.observer.observe(target, { childList: true, subtree: true, characterData: true });
              return 'enabled';
            };

            S.disableObserver = function() {
              if (S.observer) {
                try { S.observer.disconnect(); } catch(e) {}
                S.observer = null;
                return 'disabled';
              }
              return 'noop';
            };

            S.setAll = function(list, opts) {
              S.store = new Map();
              if (Array.isArray(list)) {
                for (let i = 0; i < list.length; i++) {
                  const item = list[i];
                  if (S._isValidPayload(item)) {
                    S.store.set(item.segmentID, item);
                  }
                }
              }
              const behavior = opts && opts.observer;
              if (behavior === 'restart' || behavior === 'disable') {
                S.disableObserver();
              }
              if (behavior === 'restart') {
                S.enableObserver();
              } else if (behavior === 'keep') {
                // 유지
              }
              return S.applyAll();
            };

            S.upsertPair = function(payload, opts) {
              if (!S._isValidPayload(payload)) return 'invalid_payload';
              S.store.set(payload.segmentID, payload);
              const immediate = opts && opts.immediate === true;
              const schedule = opts && opts.schedule === true;
              const highlight = opts && opts.highlight === true;
              if (immediate) {
                return 'applied:' + S.applyPayload(payload, { highlight: highlight });
              }
              if (schedule) {
                return S.scheduleApply(null);
              }
              return 'stored';
            };

            window.__afmInline = S;
          }
          const __afmInline = window.__afmInline;
    """
    }

    static var bootstrapSuffix: String {
        """
          return __afmInline;
        })();
        """
    }
}

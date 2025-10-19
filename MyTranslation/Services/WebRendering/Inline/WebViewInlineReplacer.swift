//
//  WebViewInlineReplacer.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

final class WebViewInlineReplacer: InlineReplacer {
    public func setPairs(
        _ pairs: [(original: String, translated: String)],
        using exec: WebViewScriptExecutor,
        observer: InlineObserverBehavior
    ) {
        let payload = pairs.map { ["o": $0.original, "t": $0.translated] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let observerValue: String
        switch observer {
        case .keep: observerValue = "keep"
        case .restart: observerValue = "restart"
        case .disable: observerValue = "disable"
        }

        let js = """
        (function(){
          const ensure = () => {
            if (!window.__afmInline) window.__afmInline = {};
            const S = window.__afmInline;

            if (typeof S.norm !== 'function') {
              S.norm = s => (s||'').replace(/\\s+/g,' ').trim();
            }

            if (!(S.map instanceof Map)) {
              S.map = new Map();
            }

            if (typeof S.shouldSkipNode !== 'function') {
              S.shouldSkipNode = (node) => {
                if (!node || node.nodeType !== Node.TEXT_NODE) return true;
                const txt = node.nodeValue;
                if (!txt || !txt.trim()) return true;
                const el = node.parentElement;
                if (!el) return true;
                if (el.closest('script,style,textarea,[contenteditable]')) return true;
                return false;
              };
            }

            if (typeof S.tryReplaceTextNode !== 'function') {
              S.tryReplaceTextNode = (node) => {
                if (S.shouldSkipNode(node)) return false;

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
                    node.nodeValue = translated;
                  }
                  node.__afmApplied = true;
                  return changed || !hadApplied;
                }

                if (hadApplied && hasStoredOriginal) {
                  const changed = node.nodeValue !== node.__afmOriginal;
                  if (changed) {
                    node.nodeValue = node.__afmOriginal;
                  }
                  node.__afmOriginal = undefined;
                  node.__afmApplied = undefined;
                  return changed;
                }

                return false;
              };
            }

            if (typeof S.applyAll !== 'function') {
              S.applyAll = (root) => {
                const r = root || document.body || document.documentElement;
                if (!r) return 0;
                const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
                let n, count = 0;
                while ((n = walker.nextNode())) { if (S.tryReplaceTextNode(n)) count++; }
                return count;
              };
            }

            if (typeof S.restoreAll !== 'function') {
              S.restoreAll = (root) => {
                const r = root || document.body || document.documentElement;
                if (!r) return 0;
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
            }

            if (typeof S._scheduleApply !== 'function') {
              S._pending = false;
              S._scheduleApply = (root) => {
                if (S._pending) return;
                S._pending = true;
                (window.requestAnimationFrame || setTimeout)(() => {
                  S._pending = false;
                  S.applyAll(root);
                }, 16);
              };
            }

            if (typeof S.enableObserver !== 'function') {
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
                      const el = m.target;
                      if (el && el.nodeType === Node.ELEMENT_NODE) S._scheduleApply(el);
                    }
                  }
                });
                const root = document.body || document.documentElement;
                if (root) {
                  S.observer.observe(root, {
                    subtree: true,
                    childList: true,
                    characterData: true,
                    attributes: true,
                    attributeFilter: ['class','open','hidden','style','aria-expanded']
                  });
                }
                return 'enabled';
              };
            }

            if (typeof S.disableObserver !== 'function') {
              S.disableObserver = () => {
                if (S.observer) { S.observer.disconnect(); S.observer = null; return 'disabled'; }
                return 'noop';
              };
            }

            if (typeof S._applyForKey !== 'function') {
              S._applyForKey = (key, root) => {
                const r = root || document.body || document.documentElement;
                if (!r) return 0;
                const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
                let n, count = 0;
                while ((n = walker.nextNode())) {
                  const source = typeof n.__afmOriginal === 'string' ? n.__afmOriginal : n.nodeValue;
                  if (S.norm(source) === key) {
                    if (S.tryReplaceTextNode(n)) count++;
                  }
                }
                return count;
              };
            }

            if (typeof S.upsertPair !== 'function') {
              S.upsertPair = (pair, opts) => {
                if (!pair || typeof pair.o !== 'string') return 'invalid_pair';
                const key = S.norm(pair.o);
                if (!(S.map instanceof Map)) S.map = new Map();
                if (typeof pair.t === 'string' && pair.t.length) {
                  S.map.set(key, pair.t);
                } else {
                  S.map.delete(key);
                }

                const immediate = opts && opts.immediate === true;
                const schedule = opts && opts.schedule === true;
                const root = opts && opts.root ? opts.root : null;
                let applied = 0;
                if (immediate) {
                  applied = S._applyForKey(key, root);
                } else if (schedule) {
                  S._scheduleApply(root);
                }
                return 'upserted:' + key + ':' + applied;
              };
            }

            return S;
          };
          const S = ensure();

          const behavior = '\(observerValue)';
          if (behavior === 'restart' || behavior === 'disable') {
            S.disableObserver && S.disableObserver();
          }

          S.map = new Map();

          const P = \(json);
          for (const p of P) {
            if (!p || typeof p.o !== 'string') continue;
            const key = S.norm(p.o);
            if (typeof p.t === 'string' && p.t.length) {
              S.map.set(key, p.t);
            } else {
              S.map.delete(key);
            }
          }

          if (behavior === 'restart') {
            S.enableObserver && S.enableObserver();
          } else if (behavior === 'keep') {
            // noop - 기존 옵저버 유지
          } else if (behavior === 'disable') {
            // 이미 disableObserver 호출됨
          }

          return 'pairs_set:' + S.map.size;
        })();
        """
        Task {
            _ = try? await exec.runJS(js)
        }
    }

    func upsertPair(
        _ pair: (original: String, translated: String),
        using exec: WebViewScriptExecutor,
        immediateApply: Bool
    ) {
        let payload: [String: String] = ["o": pair.original, "t": pair.translated]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = """
        (function(){
          const ensure = () => {
            if (!window.__afmInline) window.__afmInline = {};
            const S = window.__afmInline;

            if (typeof S.norm !== 'function') {
              S.norm = s => (s||'').replace(/\\s+/g,' ').trim();
            }

            if (!(S.map instanceof Map)) {
              S.map = new Map();
            }

            if (typeof S.shouldSkipNode !== 'function') {
              S.shouldSkipNode = (node) => {
                if (!node || node.nodeType !== Node.TEXT_NODE) return true;
                const txt = node.nodeValue;
                if (!txt || !txt.trim()) return true;
                const el = node.parentElement;
                if (!el) return true;
                if (el.closest('script,style,textarea,[contenteditable]')) return true;
                return false;
              };
            }

            if (typeof S.tryReplaceTextNode !== 'function') {
              S.tryReplaceTextNode = (node) => {
                if (S.shouldSkipNode(node)) return false;

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
                    node.nodeValue = translated;
                  }
                  node.__afmApplied = true;
                  return changed || !hadApplied;
                }

                if (hadApplied && hasStoredOriginal) {
                  const changed = node.nodeValue !== node.__afmOriginal;
                  if (changed) {
                    node.nodeValue = node.__afmOriginal;
                  }
                  node.__afmOriginal = undefined;
                  node.__afmApplied = undefined;
                  return changed;
                }

                return false;
              };
            }

            if (typeof S.applyAll !== 'function') {
              S.applyAll = (root) => {
                const r = root || document.body || document.documentElement;
                if (!r) return 0;
                const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
                let n, count = 0;
                while ((n = walker.nextNode())) { if (S.tryReplaceTextNode(n)) count++; }
                return count;
              };
            }

            if (typeof S.restoreAll !== 'function') {
              S.restoreAll = (root) => {
                const r = root || document.body || document.documentElement;
                if (!r) return 0;
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
            }

            if (typeof S._scheduleApply !== 'function') {
              S._pending = false;
              S._scheduleApply = (root) => {
                if (S._pending) return;
                S._pending = true;
                (window.requestAnimationFrame || setTimeout)(() => {
                  S._pending = false;
                  S.applyAll(root);
                }, 16);
              };
            }

            if (typeof S.enableObserver !== 'function') {
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
                      const el = m.target;
                      if (el && el.nodeType === Node.ELEMENT_NODE) S._scheduleApply(el);
                    }
                  }
                });
                const root = document.body || document.documentElement;
                if (root) {
                  S.observer.observe(root, {
                    subtree: true,
                    childList: true,
                    characterData: true,
                    attributes: true,
                    attributeFilter: ['class','open','hidden','style','aria-expanded']
                  });
                }
                return 'enabled';
              };
            }

            if (typeof S.disableObserver !== 'function') {
              S.disableObserver = () => {
                if (S.observer) { S.observer.disconnect(); S.observer = null; return 'disabled'; }
                return 'noop';
              };
            }

            if (typeof S._applyForKey !== 'function') {
              S._applyForKey = (key, root) => {
                const r = root || document.body || document.documentElement;
                if (!r) return 0;
                const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
                let n, count = 0;
                while ((n = walker.nextNode())) {
                  const source = typeof n.__afmOriginal === 'string' ? n.__afmOriginal : n.nodeValue;
                  if (S.norm(source) === key) {
                    if (S.tryReplaceTextNode(n)) count++;
                  }
                }
                return count;
              };
            }

            if (typeof S.upsertPair !== 'function') {
              S.upsertPair = (pair, opts) => {
                if (!pair || typeof pair.o !== 'string') return 'invalid_pair';
                const key = S.norm(pair.o);
                if (!(S.map instanceof Map)) S.map = new Map();
                if (typeof pair.t === 'string' && pair.t.length) {
                  S.map.set(key, pair.t);
                } else {
                  S.map.delete(key);
                }

                const immediate = opts && opts.immediate === true;
                const schedule = opts && opts.schedule === true;
                const root = opts && opts.root ? opts.root : null;
                let applied = 0;
                if (immediate) {
                  applied = S._applyForKey(key, root);
                } else if (schedule) {
                  S._scheduleApply(root);
                }
                return 'upserted:' + key + ':' + applied;
              };
            }

            return S;
          };
          const S = ensure();

          return S.upsertPair(\(json), { immediate: \(immediateApply ? "true" : "false"), schedule: true });
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

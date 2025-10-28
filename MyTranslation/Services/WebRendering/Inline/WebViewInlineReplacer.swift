//
//  WebViewInlineReplacer.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

/// NOTE: JS 브릿지 명세는 Docs/streaming-translation-contract.md 를 따른다.
/// window.__afmInline.upsertPayload({ segmentID, originalText, translatedText, engineID, sequence }) 형태로 호출된다.
final class WebViewInlineReplacer: InlineReplacer {
    private static let ensureScript: String = {
        return #"""
(function(){
  if (!window.__afmInline) window.__afmInline = {};
  const S = window.__afmInline;

  if (!(S.translationBySid instanceof Map)) {
    S.translationBySid = new Map();
  }

  if (!(S.payloadBySegment instanceof Map)) {
    S.payloadBySegment = new Map();
  }

  if (typeof S._getSegmentElement !== 'function') {
    S._getSegmentElement = function(node) {
      if (!node) return null;
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.matches && node.matches('[data-seg-id]')) return node;
        if (node.closest) {
          const wrap = node.closest('[data-seg-id]');
          if (wrap) return wrap;
        }
        return null;
      }
      if (node.nodeType === Node.TEXT_NODE) {
        const parent = node.parentElement;
        if (!parent) return null;
        if (parent.matches && parent.matches('[data-seg-id]')) return parent;
        if (parent.closest) {
          const wrap = parent.closest('[data-seg-id]');
          if (wrap) return wrap;
        }
      }
      return null;
    };
  }

  if (typeof S._getSegmentId !== 'function') {
    S._getSegmentId = function(node) {
      if (!node) return null;
      if (node.__afmSegmentId) return String(node.__afmSegmentId);
      const element = S._getSegmentElement(node);
      if (element && element.dataset && element.dataset.segId) {
        const sid = String(element.dataset.segId);
        element.__afmSegmentId = sid;
        node.__afmSegmentId = sid;
        return sid;
      }
      return null;
    };
  }

  if (typeof S.shouldSkipNode !== 'function') {
    S.shouldSkipNode = function(node) {
      if (!node || node.nodeType !== Node.TEXT_NODE) return true;
      if (S._getSegmentId(node)) return false;
      const txt = node.nodeValue;
      if (!txt || !txt.trim()) return true;
      const el = node.parentElement;
      if (!el) return true;
      if (el.closest && el.closest('script,style,textarea,[contenteditable]')) return true;
      return false;
    };
  }

  if (typeof S._collectSegmentElements !== 'function') {
    S._collectSegmentElements = function(root) {
      if (!root) return [];
      if (root.nodeType === Node.TEXT_NODE) {
        const el = S._getSegmentElement(root);
        return el ? [el] : [];
      }
      const out = [];
      if (root.nodeType === Node.ELEMENT_NODE && root.matches && root.matches('[data-seg-id]')) {
        out.push(root);
      }
      const list = root.querySelectorAll ? root.querySelectorAll('[data-seg-id]') : [];
      for (let i = 0; i < list.length; i++) out.push(list[i]);
      return out;
    };
  }

  if (typeof S._findExclusiveAnchor !== 'function') {
    S._findExclusiveAnchor = function(element) {
      if (!element || element.nodeType !== Node.ELEMENT_NODE) return null;

      const isAnchor = function(node) {
        if (!node || node.nodeType !== Node.ELEMENT_NODE) return false;
        const tag = node.tagName ? node.tagName.toUpperCase() : '';
        return tag === 'A';
      };

      const isWhitespace = function(node) {
        return node && node.nodeType === Node.TEXT_NODE && (!node.nodeValue || !node.nodeValue.trim());
      };

      const anchorWrapsOnly = function(anchor, child) {
        if (!anchor || !child) return false;
        const nodes = anchor.childNodes;
        if (!nodes || !nodes.length) return false;
        let seen = false;
        for (let i = 0; i < nodes.length; i++) {
          const node = nodes[i];
          if (node === child) {
            if (seen) return false;
            seen = true;
            continue;
          }
          if (isWhitespace(node)) continue;
          return false;
        }
        return seen;
      };

      const findChildAnchor = function(container) {
        const nodes = container.childNodes;
        if (!nodes || !nodes.length) return null;
        let anchor = null;
        for (let i = 0; i < nodes.length; i++) {
          const child = nodes[i];
          if (isWhitespace(child)) continue;
          if (child.nodeType !== Node.ELEMENT_NODE) return null;
          if (anchor) return null;
          if (isAnchor(child)) {
            anchor = child;
            continue;
          }
          return null;
        }
        return anchor;
      };

      const tag = element.tagName ? element.tagName.toUpperCase() : '';
      if (tag === 'A') return { anchor: element, mode: 'self' };

      const parent = element.parentElement;
      if (isAnchor(parent) && anchorWrapsOnly(parent, element)) {
        return { anchor: parent, mode: 'wrapped' };
      }

      const childAnchor = findChildAnchor(element);
      if (childAnchor) {
        return { anchor: childAnchor, mode: 'child' };
      }

      return null;
    };
  }

  if (typeof S._applySegmentElement !== 'function') {
    S._applySegmentElement = function(element, sid) {
      if (!element || !sid) return false;
      element.__afmSegmentId = sid;
      const hasTranslation = S.translationBySid instanceof Map && S.translationBySid.has(sid);
      const translated = hasTranslation ? S.translationBySid.get(sid) : null;
      let anchorInfo = null;
      if (hasTranslation && typeof translated === 'string' && translated.length) {
        anchorInfo = S._findExclusiveAnchor(element);
      }
      const anchor = anchorInfo ? anchorInfo.anchor : null;
      const anchorMode = anchorInfo ? anchorInfo.mode : null;

      if (hasTranslation && typeof translated === 'string' && translated.length) {
        if (element.__afmAppliedBy && element.__afmAppliedBy !== sid) return false;
        let changed = false;
        if (anchor) {
          element.__afmAnchorRef = anchor;
          element.__afmAnchorMode = anchorMode;
          if (anchorMode === 'self' || anchorMode === 'child') {
            if (!('__afmOriginalHtml' in anchor)) {
              anchor.__afmOriginalHtml = anchor.innerHTML;
            }
            if (anchor.textContent !== translated) {
              anchor.textContent = translated;
              changed = true;
            }
          } else {
            if (typeof element.__afmOriginalText !== 'string') {
              element.__afmOriginalText = element.textContent;
            }
            if (element.textContent !== translated) {
              element.textContent = translated;
              changed = true;
            }
          }
          element.__afmAppliedMode = 'anchor';
          anchor.__afmAppliedBy = sid;
        } else {
          element.__afmAnchorRef = undefined;
          element.__afmAnchorMode = undefined;
          if (typeof element.__afmOriginalText !== 'string') {
            element.__afmOriginalText = element.textContent;
          }
          if (element.textContent !== translated) {
            // Use SID-based replacement (no substring matching)
            element.textContent = translated;
            changed = true;
          }
          element.__afmAppliedMode = 'text';
        }
        element.__afmAppliedBy = sid;
        return changed;
      }

      if (element.__afmAppliedBy === sid) {
        if (element.__afmAppliedMode === 'anchor') {
          const anchor = element.__afmAnchorRef;
          const mode = element.__afmAnchorMode;
          let changed = false;
          if (anchor && (mode === 'self' || mode === 'child')) {
            if ('__afmOriginalHtml' in anchor && anchor.innerHTML !== anchor.__afmOriginalHtml) {
              anchor.innerHTML = anchor.__afmOriginalHtml;
              changed = true;
            }
            anchor.__afmOriginalHtml = undefined;
            anchor.__afmAppliedBy = undefined;
          } else if (typeof element.__afmOriginalText === 'string') {
            if (element.textContent !== element.__afmOriginalText) {
              element.textContent = element.__afmOriginalText;
              changed = true;
            }
            element.__afmOriginalText = undefined;
          }
          element.__afmAnchorRef = undefined;
          element.__afmAnchorMode = undefined;
          element.__afmAppliedBy = undefined;
          element.__afmAppliedMode = undefined;
          return changed;
        }
        if (typeof element.__afmOriginalText === 'string') {
          const changed = element.textContent !== element.__afmOriginalText;
          if (changed) {
            element.textContent = element.__afmOriginalText;
          }
          element.__afmAppliedBy = undefined;
          element.__afmOriginalText = undefined;
          element.__afmAppliedMode = undefined;
          return changed;
        }
      }

      return false;
    };
  }

  if (typeof S.tryReplaceTextNode !== 'function') {
    S.tryReplaceTextNode = function(node) {
      if (S.shouldSkipNode(node)) return false;
      const element = S._getSegmentElement(node);
      if (!element) return false;
      const sid = S._getSegmentId(element);
      if (!sid) return false;
      return S._applySegmentElement(element, sid);
    };
  }

  if (typeof S.applyAll !== 'function') {
    S.applyAll = function(root) {
      const r = root || document;
      if (!r) return 0;
      const targets = S._collectSegmentElements(r);
      let count = 0;
      for (let i = 0; i < targets.length; i++) {
        const el = targets[i];
        const sid = S._getSegmentId(el);
        if (!sid) continue;
        if (S._applySegmentElement(el, sid)) count++;
      }
      return count;
    };
  }

  if (typeof S.restoreAll !== 'function') {
    S.restoreAll = function(root) {
      const r = root || document;
      if (!r) return 0;
      const targets = S._collectSegmentElements(r);
      let count = 0;
      for (let i = 0; i < targets.length; i++) {
        const el = targets[i];
        const sid = S._getSegmentId(el);
        if (!sid) continue;
        if (el.__afmAppliedBy === sid && typeof el.__afmOriginalText === 'string') {
          const changed = el.textContent !== el.__afmOriginalText;
          if (changed) {
            el.textContent = el.__afmOriginalText;
          }
          el.__afmAppliedBy = undefined;
          el.__afmOriginalText = undefined;
          count += changed ? 1 : 0;
        }
      }
      return count;
    };
  }

  if (typeof S._scheduleApply !== 'function') {
    S._pending = false;
    S._scheduleApply = function(root) {
      if (S._pending) return;
      S._pending = true;
      (window.requestAnimationFrame || setTimeout)(function(){
        S._pending = false;
        S.applyAll(root);
      }, 16);
    };
  }

  if (typeof S._applyForSegment !== 'function') {
    S._applyForSegment = function(sid, root) {
      if (!sid) return 0;
      const r = root || document;
      if (!r) return 0;
      const targets = S._collectSegmentElements(r);
      let count = 0;
      for (let i = 0; i < targets.length; i++) {
        const el = targets[i];
        const currentSid = S._getSegmentId(el);
        if (currentSid !== sid) continue;
        if (S._applySegmentElement(el, sid)) count++;
      }
      return count;
    };
  }

  if (typeof S.enableObserver !== 'function') {
    S.enableObserver = function() {
      if (S.observer) return 'exists';
      S.observer = new MutationObserver(function(muts){
        for (const m of muts) {
          if (m.type === 'childList') {
            m.addedNodes && m.addedNodes.forEach(function(node){
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
    S.disableObserver = function() {
      if (S.observer) { S.observer.disconnect(); S.observer = null; return 'disabled'; }
      return 'noop';
    };
  }

  if (typeof S._syncPayload !== 'function') {
    S._syncPayload = function(payload) {
      if (!payload || payload.segmentID === undefined) return '';
      const sid = String(payload.segmentID);
      if (!(S.payloadBySegment instanceof Map)) {
        S.payloadBySegment = new Map();
      }
      S.payloadBySegment.set(sid, payload);
      if (typeof payload.translatedText === 'string' && payload.translatedText.length) {
        S.translationBySid.set(sid, payload.translatedText);
      } else {
        S.translationBySid.delete(sid);
      }
      return sid;
    };
  }

  if (typeof S.setInitialPayloads !== 'function') {
    S.setInitialPayloads = function(payloads, opts) {
      if (!Array.isArray(payloads)) return 'invalid_payloads';
      S.translationBySid = new Map();
      S.payloadBySegment = new Map();
      let count = 0;
      for (const item of payloads) {
        const sid = S._syncPayload(item);
        if (sid) count++;
      }
      const behavior = opts && opts.behavior;
      if (behavior === 'restart') {
        S.disableObserver && S.disableObserver();
        S.enableObserver && S.enableObserver();
      } else if (behavior === 'disable') {
        S.disableObserver && S.disableObserver();
      }
      return 'payloads_set:' + count;
    };
  }

  if (typeof S.upsertPayload !== 'function') {
    S.upsertPayload = function(payload, opts) {
      if (!payload || payload.segmentID === undefined) return 'invalid_payload';
      const sid = S._syncPayload(payload);
      const applyImmediately = opts && opts.applyImmediately === true;
      const highlight = opts && opts.highlight === true;
      const root = opts && opts.root ? opts.root : null;
      const schedule = opts && opts.schedule === true;
      let applied = 0;
      if (applyImmediately) {
        applied = S._applyForSegment(sid, root);
      } else if (schedule !== false) {
        S._scheduleApply(root);
      }
      if (highlight && window.MT && typeof window.MT.HILITE === 'function') {
        try { window.MT.HILITE(String(payload.segmentID)); } catch (e) { console.warn('[InlineReplacer] highlight failed', e); }
      }
      if (applyImmediately && S.enableObserver) { S.enableObserver(); }
      return 'upsert:' + sid + ':' + applied;
    };
  }

  return S;
})()
"""#
    }()

    static func scriptForTesting() -> String { ensureScript }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private func observerString(for behavior: InlineObserverBehavior) -> String {
        switch behavior {
        case .keep: return "keep"
        case .restart: return "restart"
        case .disable: return "disable"
        }
    }

    func setPairs(
        _ payloads: [TranslationStreamPayload],
        using exec: WebViewScriptExecutor,
        observer: InlineObserverBehavior
    ) {
        guard let data = try? encoder.encode(payloads),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = """
        (function(payloads, behavior){
          const S = \(WebViewInlineReplacer.ensureScript);
          if (!S || !S.setInitialPayloads) return 'no_state';
          return S.setInitialPayloads(payloads, { behavior: behavior });
        })(\(json), '\(observerString(for: observer))');
        """

        Task { _ = try? await exec.runJS(js) }
    }

    func apply(using exec: WebViewScriptExecutor, observe: Bool) {
        let js = """
        (function(observe){
          const S = \(WebViewInlineReplacer.ensureScript);
          if (!S || !S.applyAll) return 'no_state';
          const count = S.applyAll(document.body || document.documentElement);
          if (observe && S.enableObserver) S.enableObserver();
          return 'applied:' + count;
        })(\(observe ? "true" : "false"));
        """

        Task { _ = try? await exec.runJS(js) }
    }

    func upsert(
        payload: TranslationStreamPayload,
        using exec: WebViewScriptExecutor,
        applyImmediately: Bool,
        highlight: Bool
    ) {
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = """
        (function(payload, applyNow, highlight){
          const S = \(WebViewInlineReplacer.ensureScript);
          if (!S || !S.upsertPayload) return 'no_state';
          return S.upsertPayload(payload, { applyImmediately: applyNow, highlight: highlight, schedule: true });
        })(\(json), \(applyImmediately ? "true" : "false"), \(highlight ? "true" : "false"));
        """

        Task { _ = try? await exec.runJS(js) }
    }

    func restore(using exec: WebViewScriptExecutor) {
        let js = """
        (function(){
          const S = \(WebViewInlineReplacer.ensureScript);
          if (!S || !S.restoreAll) return 'no_state';
          const count = S.restoreAll(document.body || document.documentElement);
          if (S.disableObserver) S.disableObserver();
          return 'restored:' + count;
        })();
        """

        Task { _ = try? await exec.runJS(js) }
    }
}

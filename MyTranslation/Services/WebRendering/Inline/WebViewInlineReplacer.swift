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

  if (typeof S.norm !== 'function') {
    S.norm = function(s){ return (s || '').replace(/\s+/g, ' ').trim(); };
  }

  if (!(S.map instanceof Map)) {
    S.map = new Map();
  }

  if (!(S.payloadBySegment instanceof Map)) {
    S.payloadBySegment = new Map();
  }

  if (typeof S.shouldSkipNode !== 'function') {
    S.shouldSkipNode = function(node) {
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
    S.tryReplaceTextNode = function(node) {
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
    S.applyAll = function(root) {
      const r = root || document.body || document.documentElement;
      if (!r) return 0;
      const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT, null);
      let n, count = 0;
      while ((n = walker.nextNode())) { if (S.tryReplaceTextNode(n)) count++; }
      return count;
    };
  }

  if (typeof S.restoreAll !== 'function') {
    S.restoreAll = function(root) {
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
    S._scheduleApply = function(root) {
      if (S._pending) return;
      S._pending = true;
      (window.requestAnimationFrame || setTimeout)(function(){
        S._pending = false;
        S.applyAll(root);
      }, 16);
    };
  }

  if (typeof S._applyForKey !== 'function') {
    S._applyForKey = function(key, root) {
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
      if (!payload || typeof payload.originalText !== 'string') return '';
      const key = S.norm(payload.originalText);
      if (!key) return key;
      if (typeof payload.translatedText === 'string' && payload.translatedText.length) {
        S.map.set(key, payload.translatedText);
      } else {
        S.map.delete(key);
      }
      if (!(S.payloadBySegment instanceof Map)) {
        S.payloadBySegment = new Map();
      }
      if (payload.segmentID !== undefined) {
        S.payloadBySegment.set(String(payload.segmentID), { key: key, payload: payload });
      }
      return key;
    };
  }

  if (typeof S.setInitialPayloads !== 'function') {
    S.setInitialPayloads = function(payloads, opts) {
      if (!Array.isArray(payloads)) return 'invalid_payloads';
      S.map = new Map();
      S.payloadBySegment = new Map();
      let count = 0;
      for (const item of payloads) {
        const key = S._syncPayload(item);
        if (key) count++;
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
      if (!payload || typeof payload.originalText !== 'string') return 'invalid_payload';
      const key = S._syncPayload(payload);
      const applyImmediately = opts && opts.applyImmediately === true;
      const highlight = opts && opts.highlight === true;
      const root = opts && opts.root ? opts.root : null;
      const schedule = opts && opts.schedule === true;
      let applied = 0;
      if (applyImmediately) {
        applied = S._applyForKey(key, root);
      } else if (schedule !== false) {
        S._scheduleApply(root);
      }
      if (highlight && window.MT && typeof window.MT.HILITE === 'function') {
        try { window.MT.HILITE(String(payload.segmentID)); } catch (e) { console.warn('[InlineReplacer] highlight failed', e); }
      }
      if (applyImmediately && S.enableObserver) { S.enableObserver(); }
      return 'upsert:' + key + ':' + applied;
    };
  }

  return S;
})()
"""#
    }()

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

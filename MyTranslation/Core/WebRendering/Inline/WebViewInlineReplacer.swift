import Foundation

/// NOTE: JS 브릿지 명세는 Docs/streaming-translation-contract.md 를 따른다.
/// window.__afmInline.upsertPayload({ segmentID, originalText, translatedText, engineID, sequence }) 형태로 호출된다.
final class WebViewInlineReplacer: InlineReplacer {
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

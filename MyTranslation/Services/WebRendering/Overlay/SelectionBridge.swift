// Services/Web/SelectionBridge.swift
import CoreGraphics
import WebKit

public struct ElementRect: Sendable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
}

final class SelectionBridge: NSObject {
    weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        injectBootstrap()
    }

    deinit { }

    func mark(segments: [Segment]) async {
        guard let webView else { return }
        let payload = segments.compactMap { segment -> [String: Any]? in
            guard let dom = segment.domRange else { return nil }
            return [
                "id": segment.id,
                "startToken": dom.startToken,
                "startOffset": dom.startOffset,
                "endToken": dom.endToken,
                "endOffset": dom.endOffset,
                "startIndex": dom.startIndex,
                "endIndex": dom.endIndex
            ]
        }
        guard payload.isEmpty == false,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(list){
          if (window.MT && window.MT_MARK_SEGMENTS_ALL) {
            return MT_MARK_SEGMENTS_ALL(list);
          } else if (window.MT && window.MT_MARK_SEGMENTS) {
            return MT_MARK_SEGMENTS(list);
          } else {
            return -999;
          }
        })(\(json));
        """
        let result = try? await webView.callAsyncJavaScript(
            js,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        print("[MARK] returned =", result ?? "nil")
    }

    private static let bootstrapScript: String = {
        return #"""
        (function () {
          if (window.MT && window.MT.BOOT_OK) return;
          window.MT = window.MT || {};

          const NODE_REGISTRY = (function () {
            const reg = window.MT.__nodeRegistry || {};
            if (!(reg.map instanceof Map)) {
              reg.map = new Map();
            }
            if (typeof reg.seq !== 'number' || !isFinite(reg.seq)) {
              reg.seq = 0;
            }
            window.MT.__nodeRegistry = reg;
            return reg;
          })();

          function ensureNodeToken(node) {
            if (!node) return null;
            if (!node.__afmNodeToken) {
              NODE_REGISTRY.seq += 1;
              node.__afmNodeToken = 'n' + NODE_REGISTRY.seq.toString(36);
            }
            NODE_REGISTRY.map.set(node.__afmNodeToken, node);
            return node.__afmNodeToken;
          }

          function getNodeByToken(token) {
            if (!token) return null;
            const reg = window.MT.__nodeRegistry;
            if (!reg || !(reg.map instanceof Map)) return null;
            return reg.map.get(token) || null;
          }

          try {
            var style = document.createElement('style');
            style.type = 'text/css';
            style.textContent = `
              [data-seg-id] { cursor: pointer; }
              [data-seg-id].mt-selected { background-color: rgba(0,145,255,0.22); outline: 2px solid rgba(0,145,255,0.5); }
            `;
            (document.head || document.documentElement).appendChild(style);
          } catch (e) {}
        
        const CH = 'mtconsole';
          ['log','warn','error'].forEach(level => {
            const orig = console[level].bind(console);
            console[level] = function(...args) {
              try { window.webkit?.messageHandlers?.[CH]?.postMessage({ level, args: args.map(a => String(a)) }); } catch(e){}
              try { orig(...args); } catch(e){}
            };
          });

          // ====== 인터랙션 충돌 회피 ======
          const INTERACTIVE_SEL = [
            'a','button','summary','label','input','textarea','select','details',
              '[role="button"]','[role="link"]','[contenteditable]','[onclick]','[aria-haspopup="true"]'
          ].join(',');

          function isInteractive(el) {
            return !!(el && el.closest && el.closest(INTERACTIVE_SEL));
          }

          // ====== 짧은 CJK 허용 로직 (유니코드 속성 미사용 폴백) ======
          // ====== 클릭 핸들러 (페이지 본문 클릭 방해 금지) ======
          document.addEventListener('click', function (e) {
            var node = e.target && e.target.closest ? e.target.closest('[data-seg-id]') : null;
            if (!node) return;

            // 인터랙티브 조상/자신이 인터랙티브면: 우리 기능 스킵 → 원래 클릭 유지
        //            if (isInteractive(node) || isInteractive(e.target)) return;

            const id = node.getAttribute('data-seg-id');
            if (!id) return;

            // 페이지 동작 우선
            const r = node.getBoundingClientRect();
            const payload = {
              id,
              text: (node.textContent || '').trim(),
              rect: { x: r.left, y: r.top, width: r.width, height: r.height }
            };
            try { window.webkit?.messageHandlers?.selection?.postMessage(id); } catch (_){}
          }, true);
        
          // ====== 마킹 (블록 단위 + Range 래핑: 노드 경계도 매칭) ======
        const BLOCK_ANCHOR_SEL = 'p, li, blockquote, h1, h2, h3, h4, h5, h6';
        
        function fragContainsBlock(frag) {
          // 블록/컨테이너/버튼류 태그 집합
            const BAD = new Set([
              'P','DIV','SECTION','ARTICLE','HEADER','FOOTER','MAIN','ASIDE','NAV',
              'UL','OL','LI','TABLE','THEAD','TBODY','TFOOT','TR','TD','TH',
              'FIGURE','FIGCAPTION','H1','H2','H3','H4','H5','H6','BUTTON'
            ]);
            function walk(node) {
              if (!node) return false;
              if (node.nodeType === 1) { // ELEMENT_NODE
                const tn = node.tagName;
                if (BAD.has(tn)) return true;
                // 자식들 검사
                for (let i = 0; i < node.childNodes.length; i++) {
                  if (walk(node.childNodes[i])) return true;
                }
                return false;
              } else {
                // 텍스트/코멘트 등
                for (let i = 0; i < node.childNodes?.length; i++) {
                  if (walk(node.childNodes[i])) return true;
                }
                return false;
              }
            }
            return walk(frag);
        }

        const BLOCK_QUERY = 'p,li,article,section,blockquote,main,aside,header,footer,div';

        function collectBlocks() {
            // body 내부의 텍스트 블록만 대상으로 제한 (head/title 제외)
            const root = document.body || document.documentElement;
            if (!root) return [];
            const nodes = Array.from(root.querySelectorAll(BLOCK_QUERY));
            const leaves = nodes.filter(el => !nodes.some(other => other !== el && el.contains(other)));
            return leaves.filter(el => {
              const txt = (el.innerText || '').trim();
              if (!txt) return false;
              if (txt.length >= 6) return true;
              for (let i = 0; i < txt.length; i++) {
                if (txt.charCodeAt(i) > 0x7f) return true;
              }
              return false;
            });
          }

          function buildIndex(block) {
            // block 하위 텍스트 노드들을 순서대로 모아 큰 문자열과 매핑 테이블 구성
            const map = []; // [{node, token, start, end}]
            let acc = '';
            const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, {
              acceptNode(n) {
                if (!n || !n.nodeValue) return NodeFilter.FILTER_REJECT;
                // 이미 래핑된 조상 제외
                if (n.parentElement && n.parentElement.closest('[data-seg-id]')) return NodeFilter.FILTER_REJECT;
                const t = n.nodeValue;
                if (!t || !t.trim()) return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            let node;
            while ((node = walker.nextNode())) {
              const start = acc.length;
              acc += node.nodeValue;
              const token = ensureNodeToken(node);
              if (!token) continue;
              map.push({ node, token, start, end: acc.length });
            }
            return { text: acc, map };
          }

          function tagTextNodesWithSegment(root, id) {
            if (!root || !id) return;
            try {
              const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
              let node;
              while ((node = walker.nextNode())) {
                node.__afmSegmentId = id;
              }
            } catch (_) {}
          }

          function buildBlockSnapshots() {
            const blocks = collectBlocks();
            const snapshots = [];
            for (let i = 0; i < blocks.length; i++) {
              const blk = blocks[i];
              const { text, map } = buildIndex(blk);
              if (!text || !map.length) continue;
              const plainMap = map.map(entry => ({ token: entry.token, start: entry.start, end: entry.end }));
              snapshots.push({ text, map: plainMap });
            }
            return snapshots;
          }

          window.MT_COLLECT_BLOCK_SNAPSHOTS = function () {
            try {
              const data = buildBlockSnapshots();
              return JSON.stringify(data);
            } catch (e) {
              return '[]';
            }
          };

          function applySegmentDescriptor(desc) {
            if (!desc || !desc.id) return false;
            const startNode = getNodeByToken(desc.startToken);
            const endNode = getNodeByToken(desc.endToken);
            if (!startNode || !endNode) return false;

            const startHost = startNode.parentElement && startNode.parentElement.closest('[data-seg-id]');
            if (startHost && startHost.getAttribute('data-seg-id') !== desc.id) return false;
            const endHost = endNode.parentElement && endNode.parentElement.closest('[data-seg-id]');
            if (endHost && endHost.getAttribute('data-seg-id') !== desc.id) return false;

            try {
              const doc = startNode.ownerDocument || document;
              const r = doc.createRange();
              r.setStart(startNode, Math.max(0, desc.startOffset || 0));
              r.setEnd(endNode, Math.max(0, desc.endOffset || 0));
              if (r.collapsed) return false;
              const probe = r.cloneContents();
              if (fragContainsBlock(probe)) return false;

              const existing = startHost || endHost;
              if (existing && existing.getAttribute('data-seg-id') === desc.id) {
                existing.__afmSegmentId = desc.id;
                existing.setAttribute('data-seg-id', desc.id);
                tagTextNodesWithSegment(existing, desc.id);
                return true;
              }

              const span = document.createElement('span');
              span.setAttribute('data-seg-id', desc.id);
              span.__afmSegmentId = desc.id;
              const frag = r.extractContents();
              span.appendChild(frag);
              tagTextNodesWithSegment(span, desc.id);
              r.insertNode(span);
              return true;
            } catch (_) {
              return false;
            }
          }

          function applySegmentsByTokens(list) {
            if (!Array.isArray(list) || !list.length) return 0;
            const sorted = list.slice().sort((a, b) => {
              const ax = typeof a.startIndex === 'number' ? a.startIndex : 0;
              const bx = typeof b.startIndex === 'number' ? b.startIndex : 0;
              if (ax === bx) return (typeof b.endIndex === 'number' ? b.endIndex : 0) - (typeof a.endIndex === 'number' ? a.endIndex : 0);
              return bx - ax;
            });
            let hits = 0;
            for (let i = 0; i < sorted.length; i++) {
              if (applySegmentDescriptor(sorted[i])) hits++;
            }
            return hits;
          }

          window.MT_MARK_SEGMENTS = function (list) {
            try { return applySegmentsByTokens(list); } catch (e) { console.log('[MT] mark error:', e?.message || e); return 0; }
          };
        
        window.MT_MARK_SEGMENTS_ALL = function(list){
          function call(win){
            let sum = 0;
            try { if (win.MT && win.MT_MARK_SEGMENTS) sum += win.MT_MARK_SEGMENTS(list); } catch(e){}
            try {
              const frames = win.frames;
              for (let i = 0; i < frames.length; i++) {
                try { sum += call(frames[i]); } catch(e){}
              }
            } catch(e){}
            return sum;
          }
          return call(window);
        };

          // ====== 하이라이트 / 클리어 / 영역 ======
          window.MT.HILITE = function (segId) {
            try {
              var q = document.querySelector('[data-seg-id="' + segId + '"]');
              if (!q) return false;
              var prev = document.querySelectorAll('[data-seg-id].mt-selected');
              for (var i = 0; i < prev.length; i++) prev[i].classList.remove('mt-selected');
              q.classList.add('mt-selected');
              return true;
            } catch (e) { return false; }
          };

          window.MT.CLEAR = function () {
            try {
              var prev = document.querySelectorAll('[data-seg-id].mt-selected');
              for (var i = 0; i < prev.length; i++) prev[i].classList.remove('mt-selected');
            } catch (e) {}
          };

          window.MT_GET_RECT = function (segId) {
            var n = document.querySelector('[data-seg-id="' + segId + '"]');
            if (!n) return null;
            var r = n.getBoundingClientRect();
            return JSON.stringify({ x: r.left, y: r.top, width: r.width, height: r.height });
          };

          window.MT.BOOT_OK = true;
        })();
        """#
    }()

    static func scriptForTesting() -> String { bootstrapScript }

    private func injectBootstrap() {
        let js = SelectionBridge.bootstrapScript
        let userScript = WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView?.configuration.userContentController.addUserScript(userScript)
    }
}

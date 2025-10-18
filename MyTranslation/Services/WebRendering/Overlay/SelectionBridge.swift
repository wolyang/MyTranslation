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

    func mark(segments: [(id: String, text: String)]) async {
        guard let webView else { return }
        let payload = segments.map { ["id": $0.id, "text": $0.text] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
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

    private func injectBootstrap() {
        let js = #"""
        (function () {
          if (window.MT && window.MT.BOOT_OK) return;
          window.MT = window.MT || {};

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
          const ONLY_PUNCT_SPACE = /^[\s~`!@#$%^&*()\-=+\[\]{}\\|;:'",.<>\/\?]+$/;
          const CJK_RE = /[\uAC00-\uD7A3\u3130-\u318F\u1100-\u11FF\u4E00-\u9FFF\u3400-\u4DBF\u3040-\u309F\u30A0-\u30FF]/;

          function isCJKOnlyShort(s) {
            const t = (s || '').trim();
            if (t.length === 0 || t.length > 2) return false;
            if (ONLY_PUNCT_SPACE.test(t)) return false; // 구두점/기호/공백만 → 제외
            return CJK_RE.test(t) && !/^[A-Za-z0-9]+$/.test(t);
          }

          function shouldWrapText(txt) {
            const t = (txt || '').trim();
            return t.length >= 6 || isCJKOnlyShort(t);
          }

          // 안전한 정규식 이스케이프
          function escReg(s) {
            return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          }
        // 원문을 공백으로 나눠 escape → 느슨한 서브패턴으로 연결
        function buildLooseRegex(text) {
          const parts = String(text || '').trim().split(/\s+/);
          const escaped = parts.map(escReg);
          const glue = '(?:\\s|\\u00A0)+';   // 스페이스/개행/NBSP 허용
          return new RegExp(escaped.join(glue), 'g');
        }

          // ====== 클릭 핸들러 (페이지 본문 클릭 방해 금지) ======
          document.addEventListener('click', function (e) {
            var node = e.target && e.target.closest ? e.target.closest('[data-seg-id]') : null;
        console.log("click event listener called");
            if (!node) return;
        console.log("node exist");

            // 인터랙티브 조상/자신이 인터랙티브면: 우리 기능 스킵 → 원래 클릭 유지
        //            if (isInteractive(node) || isInteractive(e.target)) return;
        //        console.log("node is not interactive");

            const id = node.getAttribute('data-seg-id');
            if (!id) return;
        console.log("node have id");

            // 페이지 동작 우선
            const r = node.getBoundingClientRect();
            const payload = {
              id,
              text: (node.textContent || '').trim(),
              rect: { x: r.left, y: r.top, width: r.width, height: r.height }
            };
        console.log("MT selection click");
            try { window.webkit?.messageHandlers?.selection?.postMessage(id); } catch (_){}
          }, true);
        
        function collectRoots() {
          const roots = [document]; // main DOM
          const all = document.querySelectorAll('*');
          for (let i = 0; i < all.length; i++) {
            const sr = all[i].shadowRoot;
            if (sr) roots.push(sr);  // shadow DOM도 순회 대상으로 추가
          }
          return roots;
        }

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

          function collectBlocks() {
            // body 내부의 텍스트 블록만 대상으로 제한 (head/title 제외)
            const root = document.body || document.documentElement;
            if (!root) return [];
            const nodes = Array.from(
              root.querySelectorAll('p,li,article,section,blockquote,main,aside,header,footer,div')
            );
            // 너무 짧거나 display:none/visibility:hidden 대강 거르기
            return nodes.filter(el => {
              // const tn = el.tagName?.toLowerCase() || '';
              // if (!tn) return false;
              // if (!el.offsetParent && getComputedStyle(el).position !== 'fixed') return false;
              const txt = (el.innerText || '').trim();
              return txt.length >= 6;
            });
          }

          function buildIndex(block) {
            // block 하위 텍스트 노드들을 순서대로 모아 큰 문자열과 매핑 테이블 구성
            const map = []; // [{node, start, end}]
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
              map.push({ node, start, end: acc.length });
            }
            return { text: acc, map };
          }

          function posToNode(map, pos) {
            // 선형 탐색으로 충분 (문자 수가 커지면 이진 탐색 가능)
            for (let i = 0; i < map.length; i++) {
              const m = map[i];
              if (pos >= m.start && pos <= m.end) {
                return { node: m.node, offset: pos - m.start };
              }
            }
            // 경계 보정
            const last = map[map.length - 1];
            return { node: last?.node || null, offset: (last ? last.end - last.start : 0) };
          }

          function markBlockWithRanges(block, patterns) {
            const { text, map } = buildIndex(block);
            if (!text || !map.length) return 0;

            const matches = [];
            for (let k = 0; k < patterns.length; k++) {
              const { id, re } = patterns[k];
              re.lastIndex = 0;
              let m;
              while ((m = re.exec(text))) {
                matches.push({ id, start: m.index, end: m.index + m[0].length });
                if (re.lastIndex === m.index) re.lastIndex++;
              }
            }
            if (!matches.length) return 0;

            matches.sort((a,b)=> a.start===b.start ? b.end - a.end : a.start - b.start);

            let hits = 0;
            for (let i = matches.length - 1; i >= 0; i--) {
              const { id, start, end } = matches[i];
              const s = posToNode(map, start);
              const e = posToNode(map, end);
              if (!s.node || !e.node) continue;

              // ① 같은 텍스트 블록(앵커) 안에서만 래핑
              const sAnchor = s.node.parentElement?.closest(BLOCK_ANCHOR_SEL);
              const eAnchor = e.node.parentElement?.closest(BLOCK_ANCHOR_SEL);
              if (!sAnchor || sAnchor !== eAnchor) continue;

              try {
                const r = (block.ownerDocument || document).createRange();
                r.setStart(s.node, s.offset);
                r.setEnd(e.node, e.offset);

                // ② 사전 점검: 블록 요소 포함 매치라면 스킵 (레이아웃 보호)
                const probe = r.cloneContents();
                if (fragContainsBlock(probe)) continue;

                const span = document.createElement('span');
                span.setAttribute('data-seg-id', id);
                // 안전 삽입: extract → append → insert
                const frag = r.extractContents();
                span.appendChild(frag);
                r.insertNode(span);
                hits++;
              } catch (_) {
                /* skip */
              }
            }
            return hits;
          }

          function markWithRanges(list) {
            if (!Array.isArray(list) || !list.length) return 0;
            const filtered = list.filter(it => shouldWrapText(it.text));
            if (!filtered.length) return 0;

            // 느슨한 매칭(공백/개행/NBSP 허용)
            const patterns = filtered.map(it => ({ id: it.id, re: buildLooseRegex(it.text) }));

            const blocks = collectBlocks();
            let hits = 0;
            for (let b = 0; b < blocks.length; b++) {
              const blk = blocks[b];
              // 인터랙티브 블록은 통째 스킵 (페이지 동작 보호)
              // if (isInteractive(blk)) continue;
              hits += markBlockWithRanges(blk, patterns);
            }
            console.log('MT_MARK_SEGMENTS hits=', hits);
            return hits;
          }

          window.MT_MARK_SEGMENTS = function (list) {
            try { return markWithRanges(list); } catch (e) { console.log('[MT] mark error:', e?.message || e); return 0; }
          };


          window.MT_MARK_SEGMENTS = function (list) {
            try { return markWithRanges(list); } catch (e) { console.log('[MT] mark error:', e?.message || e); return 0; }
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
        let userScript = WKUserScript(
            source: js,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView?.configuration.userContentController.addUserScript(userScript)
    }
}

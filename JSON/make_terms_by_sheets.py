# make_terms_by_sheets.py
import csv, json, sys, pathlib
from collections import defaultdict, OrderedDict

# 파일명 → 카테고리 매핑 (파일명 그대로 쓰면 동일)
CATS = ["울트라맨","캐릭터명","괴수, 성인","도구, 폼, 기술명","조직","커플링명","기타"]

def parse_variants_field(raw):
    raw = (raw or "").strip()
    if not raw:
        return []
    variants = []
    for part in raw.split(","):
        v = (part or "").strip()
        if v:
            variants.append(v)
    return uniq_preserve(variants)


def uniq_preserve(arr):
    seen = OrderedDict()
    for x in arr:
        x = (x or "").strip()
        if x and x not in seen:
            seen[x] = True
    return list(seen.keys())


def load_terms(fp, category):
    rows = []
    with open(fp, "r", encoding="utf-8-sig", newline="") as f:
        rdr = csv.reader(f)
        for row in rdr:
            if not row or len(row) < 2: 
                continue
            zh = (row[0] or "").strip()
            ko = (row[1] or "").strip()
            variants = []
            if len(row) >= 3:
                variants = parse_variants_field(row[2])
            if not zh or not ko:
                continue
            # 헤더 스킵 추정
            head = {zh.lower(), ko.lower()}
            if "source" in head or "target" in head or "중국어" in head or "한국어" in head:
                continue
            rows.append({
                "source": zh,
                "target": ko,
                "category": category,
                "variants": variants
            })
    return rows

def uniq_sorted(arr):
    # 길이 내림차순 → 동길이 사전순
    seen = OrderedDict()
    for x in arr:
        x = (x or "").strip()
        if x:
            seen[x] = True
    return sorted(seen.keys(), key=lambda s: (-len(s), s))

def load_char_details(path):
    people = defaultdict(lambda: {
        "person_id": None,
        "name": {
            "family": {"source": [], "target": None, "variants": []},
            "given":  {"source": [], "target": None, "variants": []},
        },
        "aliases": []  # 임시로 list에 쌓고, 마지막에 target별 묶음
    })

    # alias 임시 버킷: pid -> target(str or None) -> set(sources)
    alias_bucket = defaultdict(lambda: defaultdict(lambda: {"sources": set(), "variants": []}))

    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = {"person_id", "part", "source", "target"}
        missing_cols = required - set(reader.fieldnames or [])
        if missing_cols:
            raise SystemExit(f"[ERR] {path} 컬럼 누락: {missing_cols}")

        for i, row in enumerate(reader, start=2):
            pid   = (row["person_id"] or "").strip()
            part  = (row["part"] or "").strip().lower()
            src   = (row["source"] or "").strip()
            tgt   = (row["target"] or "").strip() or None
            variants = parse_variants_field(row.get("variants", ""))
            if not pid or not part or not src:
                # 비어 있는 행은 스킵
                continue

            p = people[pid]
            p["person_id"] = pid

            if part == "family":
                p["name"]["family"]["source"].append(src)
                # target이 여러 값으로 들어오면 첫 값 고정, 다르면 경고만
                if tgt:
                    if p["name"]["family"]["target"] is None:
                        p["name"]["family"]["target"] = tgt
                    elif p["name"]["family"]["target"] != tgt:
                        print(f"[WARN] family target 불일치(pid={pid}): "
                              f"{p['name']['family']['target']} vs {tgt}")
                p["name"]["family"]["variants"].extend(variants)
            elif part == "given":
                p["name"]["given"]["source"].append(src)
                if tgt:
                    if p["name"]["given"]["target"] is None:
                        p["name"]["given"]["target"] = tgt
                    elif p["name"]["given"]["target"] != tgt:
                        print(f"[WARN] given target 불일치(pid={pid}): "
                              f"{p['name']['given']['target']} vs {tgt}")
                p["name"]["given"]["variants"].extend(variants)
            elif part == "alias":
                bucket = alias_bucket[pid][tgt]
                bucket["sources"].add(src)
                bucket["variants"].extend(variants)
            else:
                print(f"[WARN] 알 수 없는 part '{part}' (row {i}) — 무시")

    # 정리: source dedup/sort + alias 묶기
    result = []
    for pid, pdata in people.items():
        pdata["name"]["family"]["source"] = uniq_sorted(pdata["name"]["family"]["source"])
        pdata["name"]["family"]["variants"] = uniq_sorted(pdata["name"]["family"]["variants"])
        pdata["name"]["given"]["source"]  = uniq_sorted(pdata["name"]["given"]["source"])
        pdata["name"]["given"]["variants"]  = uniq_sorted(pdata["name"]["given"]["variants"])

        # alias: target별로 source 리스트 묶기
        aliases = []
        for tgt, bucket in alias_bucket[pid].items():
            aliases.append({
                "source": uniq_sorted(list(bucket["sources"])),
                "target": tgt,  # None 허용
                "variants": uniq_sorted(bucket["variants"])
            })
        # 길이 긴 source부터 오는 게 매칭 안정에 유리(선택)
        aliases.sort(key=lambda a: (-len(a["source"][0]) if a["source"] else 0, a["target"] or ""))
        pdata["aliases"] = aliases

        result.append({
            "person_id": pid,
            "name": pdata["name"],
            "aliases": pdata["aliases"]
        })

    return result

def main():
    # 폴더 내 CSV 전부 스캔
    folder = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    items_map = OrderedDict()
    for cat in CATS:
        fp = folder / f"울트라맨 in 중국어 - {cat}.csv"
        if not fp.exists():
            continue
        for it in load_terms(fp, cat):
            key = (it["source"], it["target"], it["category"])
            if key in items_map:
                merged = items_map[key]
                merged["variants"] = uniq_sorted(merged.get("variants", []) + it.get("variants", []))
            else:
                items_map[key] = {
                    "source": it["source"],
                    "target": it["target"],
                    "category": it["category"],
                    "variants": uniq_sorted(it.get("variants", []))
                }
    items = list(items_map.values())

    fp = folder / f"울트라맨 in 중국어 - 캐릭터명_상세.csv"
    people = load_char_details(fp)

    payload = {"meta": {"version": 3, "lang": "zh->ko"}, "terms": items, "people": people}
    out = folder / "glossary.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"written {out} ({len(items)} terms, {len(people)} people)")

if __name__ == "__main__":
    main()

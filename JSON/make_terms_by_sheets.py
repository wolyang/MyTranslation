# make_terms_by_sheets.py
import csv, json, sys, pathlib

# 파일명 → 카테고리 매핑 (파일명 그대로 쓰면 동일)
CATS = ["울트라맨","캐릭터명","괴수, 성인","도구, 폼, 기술명","조직","커플링명","기타"]

def load_csv(fp, category):
    rows = []
    with open(fp, "r", encoding="utf-8-sig", newline="") as f:
        rdr = csv.reader(f)
        for row in rdr:
            if not row or len(row) < 2: 
                continue
            zh = (row[0] or "").strip()
            ko = (row[1] or "").strip()
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
                "strict": True,
                "variants": [],
                "notes": None
            })
    return rows

def main():
    # 폴더 내 CSV 전부 스캔
    folder = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    items = []
    seen = set()
    for cat in CATS:
        fp = folder / f"울트라맨 in 중국어 - {cat}.csv"
        if not fp.exists():
            continue
        for it in load_csv(fp, cat):
            key = (it["source"], it["target"], it["category"])
            if key in seen: 
                continue
            seen.add(key)
            items.append(it)

    payload = {"meta": {"version": 3, "lang": "zh->ko"}, "terms": items}
    out = folder / "terms.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"written {out} ({len(items)} terms)")

if __name__ == "__main__":
    main()

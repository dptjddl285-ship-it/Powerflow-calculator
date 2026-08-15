"""Generate standalone HTML visual review dashboard comparing original vs boxed images side-by-side."""

import glob
import os
import json
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS_DIR = PROJECT_ROOT / "feedback_artifacts" / "antigravity_independent_loop"
NEW_PIC_DIR = PROJECT_ROOT / "new pictures"
BOXED_DIR = ARTIFACTS_DIR / "new_pictures"

ITEMS = [
    ("KakaoTalk_20260815_154947878_02.jpg", "체크리스트 #1/#2: 소형 크롭 부품 검출", "Bus:6, Gen:4, Load:3"),
    ("KakaoTalk_20260815_154947878_06.jpg", "체크리스트 #3-#6, #8, #9: 누락 Bus 및 Load 복구", "Bus:23(+2), Gen:10, Load:14(+5), Trans:3"),
    ("KakaoTalk_20260815_154947878_08.jpg", "체크리스트 #7, #10/#11: 누락 변압기 복구", "Bus:14, Gen:6, Load:12, Trans:2(+2)"),
    ("KakaoTalk_20260815_154947878_09.jpg", "체크리스트 #12/#13: 39개 버스바 온전한 길이 보존", "Bus:39(Intact), Gen:10, Load:19, Trans:13"),
    ("KakaoTalk_20260815_154947878_13.jpg", "체크리스트 #14-#16: 발전기/부하 진성 부품 Veto 방지", "Bus:24, Gen:10, Load:16, Trans:5"),
    ("KakaoTalk_20260815_154956634_04.jpg", "체크리스트 #17-#20: 누락 변압기 4개 전원 복구", "Bus:31, Gen:6, Load:22, Trans:4(+4)"),
    ("KakaoTalk_20260815_154956634_05.jpg", "체크리스트 #21-#24: 누락 부하 복구", "Bus:30, Gen:6, Load:19(+2)"),
    ("KakaoTalk_20260815_154947878.jpg", "전체 회로 도면 검출", "Bus:13, Gen:5, Load:10, Trans:3"),
    ("KakaoTalk_20260815_154947878_01.jpg", "전체 회로 도면 검출", "Bus:14, Gen:7, Load:11, Trans:3"),
    ("KakaoTalk_20260815_154947878_03.jpg", "IEEE 30 bus 도면", "Bus:30, Gen:7, Load:20, Trans:0"),
    ("KakaoTalk_20260815_154947878_04.jpg", "IEEE 30 bus 도면", "Bus:30, Gen:6, Load:0, Trans:4"),
    ("KakaoTalk_20260815_154947878_05.jpg", "IEEE 14 bus 도면", "Bus:14, Gen:2, Load:11, Trans:0"),
    ("KakaoTalk_20260815_154947878_07.jpg", "IEEE 30 bus 도면", "Bus:30, Gen:3, Load:21, Trans:4"),
    ("KakaoTalk_20260815_154947878_10.jpg", "소형 크롭 도면", "Bus:6, Gen:2, Load:3, Trans:2"),
    ("KakaoTalk_20260815_154947878_11.jpg", "6 bus 도면", "Bus:6, Gen:3, Load:3, Trans:0"),
    ("KakaoTalk_20260815_154947878_12.jpg", "6 bus 도면", "Bus:6, Gen:3, Load:3, Trans:0"),
    ("KakaoTalk_20260815_154956634.jpg", "IEEE 30 bus 도면", "Bus:30, Gen:6, Load:21, Trans:0"),
    ("KakaoTalk_20260815_154956634_01.jpg", "IEEE 30 bus 도면", "Bus:30, Gen:5, Load:20, Trans:0"),
    ("KakaoTalk_20260815_154956634_02.jpg", "IEEE 14 bus 도면", "Bus:14, Gen:2, Load:11, Trans:0"),
    ("KakaoTalk_20260815_154956634_03.jpg", "IEEE 14 bus 도면", "Bus:14, Gen:10, Load:12, Trans:0"),
]

def generate_html():
    cards_html = []
    for idx, (filename, desc, stats) in enumerate(ITEMS, 1):
        stem = Path(filename).stem
        orig_rel = f"../../new pictures/{filename}"
        boxed_rel = f"new_pictures/{stem}_boxed.jpg"
        sbs_rel = f"new_pictures/{stem}_side_by_side.jpg"

        cards_html.append(f"""
        <div class="card" id="card-{idx}">
            <div class="card-header">
                <span class="badge">#{idx:02d}</span>
                <h3>{filename}</h3>
                <span class="desc">{desc}</span>
                <span class="stats">{stats}</span>
            </div>
            <div class="comparison-grid">
                <div class="img-box">
                    <div class="img-label">원본 이미지 (Original)</div>
                    <img src="{orig_rel}" alt="Original {filename}" loading="lazy" onclick="openModal('{orig_rel}')" />
                </div>
                <div class="img-box">
                    <div class="img-label">검출 결과 (Detection Boxed)</div>
                    <img src="{boxed_rel}" alt="Boxed {filename}" loading="lazy" onclick="openModal('{boxed_rel}')" />
                </div>
            </div>
        </div>
        """)

    html_content = f"""<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Powerflow-calculator 외부 20장 도면 검출 전수 비교 갤러리</title>
    <style>
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background: #0f172a; color: #f8fafc; padding: 24px; }}
        header {{ text-align: center; margin-bottom: 32px; padding-bottom: 20px; border-bottom: 1px solid #334155; }}
        h1 {{ font-size: 26px; font-weight: 700; color: #38bdf8; margin-bottom: 8px; }}
        p.subtitle {{ font-size: 14px; color: #94a3b8; }}
        .gallery-container {{ display: flex; flex-direction: column; gap: 28px; max-width: 1400px; margin: 0 auto; }}
        .card {{ background: #1e293b; border-radius: 12px; border: 1px solid #334155; overflow: hidden; box-shadow: 0 4px 12px rgba(0,0,0,0.3); }}
        .card-header {{ display: flex; align-items: center; gap: 12px; padding: 14px 20px; background: #0f172a; border-bottom: 1px solid #334155; flex-wrap: wrap; }}
        .badge {{ background: #0284c7; color: #fff; padding: 4px 10px; border-radius: 6px; font-weight: 700; font-size: 13px; }}
        .card-header h3 {{ font-size: 16px; color: #f1f5f9; font-family: monospace; }}
        .desc {{ font-size: 13px; color: #38bdf8; font-weight: 600; background: rgba(56, 189, 248, 0.1); padding: 4px 8px; border-radius: 4px; }}
        .stats {{ margin-left: auto; font-size: 13px; color: #4ade80; font-weight: 600; }}
        .comparison-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px; padding: 20px; }}
        .img-box {{ background: #0f172a; border: 1px solid #334155; border-radius: 8px; padding: 10px; display: flex; flex-direction: column; }}
        .img-label {{ font-size: 12px; font-weight: 700; color: #94a3b8; margin-bottom: 8px; text-transform: uppercase; }}
        .img-box img {{ width: 100%; height: auto; border-radius: 4px; cursor: pointer; transition: transform 0.2s; background: #fff; }}
        .img-box img:hover {{ transform: scale(1.01); }}
        
        /* Modal for full screen zoom */
        #modal {{ display: none; position: fixed; z-index: 1000; left: 0; top: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.9); justify-content: center; align-items: center; }}
        #modal img {{ max-width: 95%; max-height: 95%; border-radius: 8px; box-shadow: 0 0 20px rgba(0,0,0,0.8); }}
        #modal:hover {{ cursor: pointer; }}
    </style>
</head>
<body>
    <header>
        <h1>⚡ Powerflow-calculator New Pictures 20장 원본 vs 검출 전수 대조 갤러리</h1>
        <p class="subtitle">Gate 1 (Train 100.0%) & Gate 2 (Matrix 99.27%) 통과 상태에서의 단일 패스 실전 검출 결과입니다. 이미지를 클릭하면 확대됩니다.</p>
    </header>
    <div class="gallery-container">
        {''.join(cards_html)}
    </div>
    <div id="modal" onclick="this.style.display='none'">
        <img id="modal-img" src="" />
    </div>
    <script>
        function openModal(src) {{
            document.getElementById('modal-img').src = src;
            document.getElementById('modal').style.display = 'flex';
        }}
    </script>
</body>
</html>
"""
    out_file = ARTIFACTS_DIR / "visual_review_dashboard.html"
    out_file.write_text(html_content, encoding="utf-8")
    print(f"Generated dashboard at {out_file}")

if __name__ == "__main__":
    generate_html()

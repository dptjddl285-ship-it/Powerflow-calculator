import pandas as pd
import os

def load_grid_data(file_name="grid_data.xlsx"):
    """
    엑셀 파일을 읽어서 파이썬 딕셔너리로 변환해주는 전담 함수
    """
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))
    EXCEL_PATH = os.path.join(BASE_DIR, file_name)

    excel_db = {
        "generators": {},
        "lines": {}
    }

    try:
        if os.path.exists(EXCEL_PATH):
            # 발전기 시트 읽기 ('Generator' 시트가 있어야 함)
            df_gen = pd.read_excel(EXCEL_PATH, sheet_name='Generator')
            excel_db["generators"] = df_gen.set_index('Gen_ID').to_dict(orient='index')
            
            # 선로 시트 읽기 ('Line' 시트가 있어야 함)
            df_line = pd.read_excel(EXCEL_PATH, sheet_name='Line')
            excel_db["lines"] = df_line.set_index('Line_ID').to_dict(orient='index')
            
            print(f"✅ 엑셀 데이터({file_name}) 로딩 성공! (발전기: {len(excel_db['generators'])}개, 선로: {len(excel_db['lines'])}개)")
        else:
            print(f"⚠️ 엑셀 파일({file_name})을 찾을 수 없습니다. 빈 DB로 시작합니다.")
    except Exception as e:
        print(f"❌ 엑셀 로딩 중 에러 발생: {e}")

    return excel_db
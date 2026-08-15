import numpy as np

def construct_y_bus(elements):
    # 1. 모선(Bus) 추출
    buses = [el for el in elements if el.get('type') == 'bus']
    bus_ids = [bus['id'] for bus in buses]
    bus_count = len(bus_ids)
    
    # ID를 인덱스(0,1,2...)로 매핑
    bus_map = {bus_id: i for i, bus_id in enumerate(bus_ids)}
    
    # 요소 ID -> 연결된 모선 ID 찾기 (선로를 발전기나 부하에 연결했을 경우를 대비해 부모 모선을 찾음)
    element_to_bus = {}
    for el in elements:
        if el.get('type') == 'bus':
            element_to_bus[el['id']] = el['id']
        elif el.get('parentBusId'):
            element_to_bus[el['id']] = el['parentBusId']
            
    # 2. Y-bus 행렬 초기화
    y_bus = np.zeros((bus_count, bus_count), dtype=complex)
    
    # 3. 선로(Line) 정보로 행렬 채우기
    lines = [el for el in elements if el.get('type') == 'line']
    
    for line in lines:
        start_el_id = line.get('startElementId')
        end_el_id = line.get('endElementId')
        
        # 선로가 연결된 진짜 모선 ID 찾기 (발전기/부하에 연결됐어도 모선 ID로 치환)
        from_id = element_to_bus.get(start_el_id)
        to_id = element_to_bus.get(end_el_id)
        
        if from_id in bus_map and to_id in bus_map:
            i, j = bus_map[from_id], bus_map[to_id]
            r = line.get('rPu', 0.0)
            x = line.get('xPu', 0.0)
            z = complex(r, x)
            
            if abs(z) > 0:
                y = 1 / z
                y_bus[i][i] += y
                y_bus[j][j] += y
                y_bus[i][j] -= y
                y_bus[j][i] -= y
                
    # 4. 터미널 출력 (printf 역할)
    print("\n" + "="*50)
    print(" 💡 [Y-Bus Matrix Calculation Result] 💡 ")
    print("="*50)
    print(f"📌 발견된 모선(Buses) 목록: {bus_ids}")
    print(f"📌 총 모선 개수: {bus_count}개")
    print("-" * 50)
    
    if bus_count > 0:
        # 콘솔 출력이 깔끔하도록 numpy 출력 옵션 설정 (소수점 4자리)
        np.set_printoptions(precision=4, suppress=True, linewidth=150)
        print("📊 계산된 Y-Bus 행렬 (Admittance Matrix):")
        print(y_bus)
    else:
        print("⚠️ 모선(Bus)이 존재하지 않아 행렬을 계산할 수 없습니다.")
    print("="*50 + "\n")
            
    return y_bus, bus_ids

# ---------------------------------------------------------
# 테스트용 코드 (직접 실행해서 프린트 결과를 확인해보고 싶을 때)
if __name__ == "__main__":
    dummy_elements = [
        {'id': 'B1', 'type': 'bus'},
        {'id': 'B2', 'type': 'bus'},
        {'id': 'B3', 'type': 'bus'},
        {'id': 'G1', 'type': 'generator', 'parentBusId': 'B1'},
        {'id': 'L1', 'type': 'line', 'startElementId': 'B1', 'endElementId': 'B2', 'rPu': 0.01, 'xPu': 0.1},
        {'id': 'L2', 'type': 'line', 'startElementId': 'B2', 'endElementId': 'B3', 'rPu': 0.02, 'xPu': 0.2},
    ]
    
    # 함수 실행 (여기서 터미널에 프린트됨)
    construct_y_bus(dummy_elements)
import re

filepath = "05_Diagnostic_Scripts/run_autonomous_loop_v8.py"
with open(filepath, "r", encoding="utf-8") as f:
    content = f.read()

# 1. mutate 함수 교체: 강도(strength) 파라미터 추가
old_mutate = '        def mutate(p):\n            new_p = json.loads(json.dumps(p))\n            if random.random() < 0.3: new_p["line_thresh"] += random.randint(-10, 10)\n            if random.random() < 0.3: new_p["line_min_len"] += random.randint(-10, 10)\n            if random.random() < 0.3: new_p["circle_param2"] += random.uniform(-2, 2)\n            for c in classes:\n                for k in new_p["rules"][c].keys():\n                    if random.random() < 0.1:\n                        new_p["rules"][c][k] *= random.uniform(0.8, 1.2)\n            return new_p'

new_mutate = '        def mutate(p, strength=1.0):\n            new_p = json.loads(json.dumps(p))\n            base = min(0.8, 0.3 * strength)\n            if random.random() < base: new_p["line_thresh"] += random.randint(-int(15*strength), int(15*strength))\n            if random.random() < base: new_p["line_min_len"] += random.randint(-int(15*strength), int(15*strength))\n            if random.random() < base: new_p["circle_param2"] += random.uniform(-3*strength, 3*strength)\n            for c in classes:\n                for k in new_p["rules"][c].keys():\n                    if random.random() < min(0.5, 0.15 * strength):\n                        new_p["rules"][c][k] *= random.uniform(max(0.5, 1.0-0.3*strength), min(1.5, 1.0+0.3*strength))\n            return new_p'

if old_mutate in content:
    content = content.replace(old_mutate, new_mutate)
    print("[OK] mutate() 함수 교체 성공")
else:
    print("[WARN] mutate() 함수를 찾지 못했습니다.")

# 2. 메인 루프: stagnation 카운터 + 동적 변이율 추가
old_loop_init = '        population = [generate_random_params() for _ in range(20)]\n        best_train = -1\n        generation = 0\n\n        while True:'
new_loop_init = '        population = [generate_random_params() for _ in range(20)]\n        best_train = -1\n        generation = 0\n        stagnation = 0  # 정체 카운터\n\n        while True:'

if old_loop_init in content:
    content = content.replace(old_loop_init, new_loop_init)
    print("[OK] 루프 초기화 교체 성공")
else:
    print("[WARN] 루프 초기화를 찾지 못했습니다.")

# 3. 점수 갱신 시 stagnation 리셋
old_score_update = '            if best_avg > best_train:\n                best_train = best_avg\n                print(f"\\n🏆 [Gen {generation}] New Best Train F1:'
new_score_update = '            if best_avg > best_train:\n                best_train = best_avg\n                stagnation = 0  # 정체 카운터 리셋\n                print(f"\\n🏆 [Gen {generation}] New Best Train F1:'

if old_score_update in content:
    content = content.replace(old_score_update, new_score_update)
    print("[OK] stagnation 리셋 로직 추가 성공")
else:
    print("[WARN] 점수 갱신 부분을 찾지 못했습니다.")

# 4. elif/else: stagnation 증가
old_elif = '            elif generation % 5 == 0:\n                print(f"[Gen {generation}] Running... Best Train F1 is still {best_train:.4f}", flush=True)'
new_elif = '            else:\n                stagnation += 1\n                if generation % 5 == 0:\n                    print(f"[Gen {generation}] Running... Best Train F1 is still {best_train:.4f} (Stagnation: {stagnation})", flush=True)'

if old_elif in content:
    content = content.replace(old_elif, new_elif)
    print("[OK] stagnation 증가 로직 추가 성공")
else:
    print("[WARN] elif 부분을 찾지 못했습니다.")

# 5. 마지막 population 갱신 부분 교체: 동적 변이율 + 대량 주입
old_pop = '            survivors = [s[1] for s in scored[:5]]\n            new_pop = survivors.copy()\n            while len(new_pop) < 20:\n                parent = random.choice(survivors)\n                new_pop.append(mutate(parent))\n                \n            for _ in range(2):\n                new_pop.append(generate_random_params())\n                \n            population = new_pop'
new_pop = '            # 동적 변이율: 정체가 길수록 탐색 강도 증가\n            mutation_strength = 1.0 + (stagnation // 10) * 0.5\n            mutation_strength = min(mutation_strength, 4.0)\n\n            if stagnation > 0 and stagnation % 30 == 0:\n                # 30세대 정체 시 새 개체 대량 주입으로 탈출 시도\n                print(f"  [Gen {generation}] 정체 {stagnation}세대! 새 개체 대량 주입으로 탈출 시도...", flush=True)\n                survivors = [s[1] for s in scored[:3]]\n                new_pop = survivors.copy()\n                for _ in range(7):\n                    new_pop.append(generate_random_params())\n                while len(new_pop) < 20:\n                    parent = random.choice(survivors)\n                    new_pop.append(mutate(parent, strength=mutation_strength))\n            else:\n                survivors = [s[1] for s in scored[:5]]\n                new_pop = survivors.copy()\n                while len(new_pop) < 20:\n                    parent = random.choice(survivors)\n                    new_pop.append(mutate(parent, strength=mutation_strength))\n                for _ in range(2):\n                    new_pop.append(generate_random_params())\n\n            population = new_pop'

if old_pop in content:
    content = content.replace(old_pop, new_pop)
    print("[OK] 동적 변이율 + 대량 주입 로직 추가 성공")
else:
    print("[WARN] population 갱신 부분을 찾지 못했습니다.")

with open(filepath, "w", encoding="utf-8") as f:
    f.write(content)

print("\n[DONE] 파일 저장 완료:", filepath)

import 'package:flutter/material.dart';

class PowerLensHomeEmptyState extends StatelessWidget {
  final VoidCallback onStartAnalysis;
  final VoidCallback onPickImage;
  final VoidCallback onLoadSample;
  final VoidCallback? onDrawManually;
  final bool isLoading;

  const PowerLensHomeEmptyState({
    super.key,
    required this.onStartAnalysis,
    required this.onPickImage,
    required this.onLoadSample,
    this.onDrawManually,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 640;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Container(
          width: isMobile ? size.width * 0.94 : 560,
          padding: EdgeInsets.all(isMobile ? 22 : 32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Header Badge & Logo
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.bolt, color: Colors.amberAccent, size: 24),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "무엇을 할까요?",
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2563EB),
                          letterSpacing: -0.2,
                        ),
                      ),
                      Text(
                        "PowerLens 시작하기",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.4,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "단선도 사진을 분석하여 계통 모델과 조류계산 결과를 만들어보세요.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isMobile ? 13 : 14,
                  color: const Color(0xFF64748B),
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              // 1. Primary CTA: [도면 사진으로 시작]
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isLoading ? null : onPickImage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    elevation: 3,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add_photo_alternate_rounded, size: 22, color: Colors.white),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              "도면 사진으로 시작",
                              style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              "내 컴퓨터나 스마트폰의 단선도 이미지 파일 선택",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withValues(alpha: 0.85),
                                fontWeight: FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.white70),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 2. Secondary CTA: [샘플로 빠르게 체험하기]
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: isLoading ? null : onLoadSample,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD97706),
                    backgroundColor: const Color(0xFFFFFBEB),
                    side: const BorderSide(color: Color(0xFFFDE68A), width: 1.2),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.flash_on_rounded, size: 22, color: Color(0xFFD97706)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Text(
                              "샘플로 빠르게 체험하기",
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFD97706),
                              ),
                            ),
                            Text(
                              "IEEE-24 모선 도면으로 10초 만에 전체 흐름 확인",
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFFB45309),
                                fontWeight: FontWeight.normal,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFFD97706)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 3. Tertiary CTA: [직접 회로도 그리기]
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: isLoading ? null : (onDrawManually ?? onStartAnalysis),
                  icon: const Icon(Icons.edit_road_rounded, size: 18, color: Color(0xFF64748B)),
                  label: const Text(
                    "직접 회로도 그리기 (빈 캔버스 열기)",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF475569),
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Divider(color: Color(0xFFF1F5F9), height: 1),
              const SizedBox(height: 18),

              // Simple 3-step Guide Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "쉬운 3단계 이용 가이드",
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF334155),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _guideRow("1", "도면 이미지 업로드", "종이 도면 사진이나 CAD 캡처본을 올립니다."),
                    const SizedBox(height: 6),
                    _guideRow("2", "AI가 객체와 연결 확인", "기호와 선로를 확인하고 번호를 매깁니다."),
                    const SizedBox(height: 6),
                    _guideRow("3", "확인 후 회로도 생성 & 조류계산", "전압과 전력 조류 흐름을 수치해석합니다."),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guideRow(String step, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 18,
          height: 18,
          margin: const EdgeInsets.only(top: 1),
          decoration: const BoxDecoration(
            color: Color(0xFFE2E8F0),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Color(0xFF475569),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              text: "$title: ",
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
              ),
              children: [
                TextSpan(
                  text: desc,
                  style: const TextStyle(
                    fontWeight: FontWeight.normal,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

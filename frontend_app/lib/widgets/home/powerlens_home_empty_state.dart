import 'package:flutter/material.dart';

class PowerLensHomeEmptyState extends StatelessWidget {
  final VoidCallback onStartAnalysis;
  final VoidCallback onPickImage;
  final VoidCallback onLoadSample;
  final bool isLoading;

  const PowerLensHomeEmptyState({
    super.key,
    required this.onStartAnalysis,
    required this.onPickImage,
    required this.onLoadSample,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 640;

    return Center(
      child: SingleChildScrollView(
        child: Container(
          width: isMobile ? size.width * 0.92 : 540,
          margin: const EdgeInsets.symmetric(vertical: 24),
          padding: EdgeInsets.all(isMobile ? 20 : 36),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo / Icon
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2563EB), Color(0xFF7C3AED)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF2563EB).withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(Icons.bolt, color: Colors.amberAccent, size: 36),
                ),
              ),
              const SizedBox(height: 18),

              // Title
              const Text(
                "PowerLens",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),

              // Subtitle
              const Text(
                "단선도를 분석하여\n전력계통 모델과 조류계산 결과를 만들어보세요.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.5,
                  color: Color(0xFF475569),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 28),

              // Primary CTA Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: isLoading ? null : onStartAnalysis,
                  icon: isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome, size: 18, color: Colors.white),
                  label: Text(
                    isLoading ? "도면 분석 준비 중..." : "단선도 AI 분석 시작하기",
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    elevation: 3,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Divider with Sub-text
              Row(
                children: [
                  const Expanded(child: Divider(color: Color(0xFFE2E8F0))),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text(
                      "이미지가 있다면 바로 분석할 수 있습니다",
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider(color: Color(0xFFE2E8F0))),
                ],
              ),
              const SizedBox(height: 16),

              // Secondary Actions
              if (isMobile) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isLoading ? null : onPickImage,
                    icon: const Icon(Icons.photo_library_outlined, size: 16),
                    label: const Text("이미지 파일 선택"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1E293B),
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isLoading ? null : onLoadSample,
                    icon: const Icon(Icons.flash_on, size: 16, color: Color(0xFFD97706)),
                    label: const Text("IEEE-24 샘플로 체험"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFD97706),
                      side: const BorderSide(color: Color(0xFFFDE68A)),
                      backgroundColor: const Color(0xFFFFFBEB),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isLoading ? null : onPickImage,
                        icon: const Icon(Icons.photo_library_outlined, size: 16),
                        label: const Text("이미지 파일 선택"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1E293B),
                          side: const BorderSide(color: Color(0xFFCBD5E1)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isLoading ? null : onLoadSample,
                        icon: const Icon(Icons.flash_on, size: 16, color: Color(0xFFD97706)),
                        label: const Text("IEEE-24 샘플로 체험"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFD97706),
                          side: const BorderSide(color: Color(0xFFFDE68A)),
                          backgroundColor: const Color(0xFFFFFBEB),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 28),

              // Workflow Roadmap
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFF1F5F9)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stepItem("1", "도면 가져오기", true),
                    const Icon(Icons.arrow_forward_ios, size: 10, color: Color(0xFFCBD5E1)),
                    _stepItem("2", "AI 검수", false),
                    const Icon(Icons.arrow_forward_ios, size: 10, color: Color(0xFFCBD5E1)),
                    _stepItem("3", "제원 연결", false),
                    const Icon(Icons.arrow_forward_ios, size: 10, color: Color(0xFFCBD5E1)),
                    _stepItem("4", "조류계산", false),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepItem(String num, String title, bool active) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              num,
              style: TextStyle(
                color: active ? Colors.white : const Color(0xFF64748B),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          title,
          style: TextStyle(
            fontSize: 10,
            fontWeight: active ? FontWeight.bold : FontWeight.w500,
            color: active ? const Color(0xFF0F172A) : const Color(0xFF94A3B8),
          ),
        ),
      ],
    );
  }
}

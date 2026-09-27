import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:circuit_solver/services/powerlens_ai_service.dart';

void main() {
  final service = PowerLensAIService.instance;

  group('PowerLens provider status', () {
    late String originalBaseUrl;

    setUp(() {
      originalBaseUrl = PowerLensAIService.baseUrl;
      service.setProviderMode('local');
    });

    tearDown(() {
      PowerLensAIService.baseUrl = originalBaseUrl;
      service.setProviderMode('local');
    });

    test(
      'uses provider status and displays Gemini model configuration',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serverDone = server.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'status': 'ok',
              'provider_mode': 'gemini',
              'display_mode': 'Gemini',
              'primary_model': 'gemini-primary-test',
              'fallback_model': 'gemini-fallback-test',
              'fallback_configured': true,
            }),
          );
          await request.response.close();
        });
        PowerLensAIService.baseUrl = 'http://127.0.0.1:${server.port}';

        try {
          await service.refreshProviderStatus();

          expect(service.geminiStatus, 'CONNECTED');
          expect(service.providerDisplayMode, 'Gemini');
          expect(service.primaryModel, 'gemini-primary-test');
          expect(service.fallbackModel, 'gemini-fallback-test');
        } finally {
          await server.close(force: true);
          await serverDone.cancel();
        }
      },
    );

    test(
      'marks the companion as local fallback when status is unreachable',
      () async {
        PowerLensAIService.baseUrl = 'http://127.0.0.1:1';

        await service.refreshProviderStatus();

        expect(service.geminiStatus, 'LOCAL_FALLBACK');
      },
    );
  });
}

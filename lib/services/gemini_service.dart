import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'settings_service.dart';

/// Google Gemini API を直接呼び出すサービス。
/// サーバー(プロキシ)は使わず、ユーザーがアプリ内で入力した
/// APIキーをそのまま使用する。
class GeminiService {
  final SettingsService settings;

  GeminiService(this.settings);

  static const String _host = 'https://generativelanguage.googleapis.com';

  Uri _streamUri() => Uri.parse(
        '$_host/v1beta/models/${settings.modelId}:streamGenerateContent'
        '?alt=sse&key=${settings.apiKey}',
      );

  /// 会話履歴("user:..."/"model:...")を Gemini の contents 形式へ変換する。
  List<Map<String, dynamic>> _historyToContents(List<String> history) {
    final contents = <Map<String, dynamic>>[];
    for (final item in history) {
      if (item.startsWith('user:')) {
        contents.add({
          'role': 'user',
          'parts': [
            {'text': item.substring(5)}
          ],
        });
      } else if (item.startsWith('model:')) {
        contents.add({
          'role': 'model',
          'parts': [
            {'text': item.substring(6)}
          ],
        });
      }
    }
    return contents;
  }

  /// ストリーミングで AI の応答を逐次返す。
  /// すべての機能（画像分析・テキスト分析・食事プラン・追問）で共用する。
  Stream<String> chatStream(
    String query,
    List<String> history, {
    File? image,
  }) async* {
    if (!settings.hasApiKey) {
      throw Exception('APIキーが設定されていません。設定画面で入力してください。');
    }

    final contents = _historyToContents(history);

    final userParts = <Map<String, dynamic>>[
      {'text': query}
    ];
    if (image != null) {
      final bytes = await image.readAsBytes();
      userParts.add({
        'inlineData': {
          'mimeType': 'image/jpeg',
          'data': base64Encode(bytes),
        }
      });
    }
    contents.add({'role': 'user', 'parts': userParts});

    final request = http.Request('POST', _streamUri());
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'contents': contents,
      'generationConfig': {
        'temperature': 0.7,
        'topK': 40,
        'topP': 0.95,
        'maxOutputTokens': 8192,
      }
    });

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);

      if (streamedResponse.statusCode != 200) {
        final body = await streamedResponse.stream.bytesToString();
        throw Exception('AI接続エラー (${streamedResponse.statusCode}): $body');
      }

      await for (final line in streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data:')) continue;
        final dataStr = line.substring(5).trim();
        if (dataStr.isEmpty || dataStr == '[DONE]') continue;
        try {
          final json = jsonDecode(dataStr);
          final text = _extractText(json);
          if (text != null && text.isNotEmpty) {
            yield text;
          }
        } catch (_) {
          // 解析できない行は無視する
        }
      }
    } finally {
      client.close();
    }
  }

  String? _extractText(dynamic json) {
    try {
      final candidates = json['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final parts = candidates[0]['content']?['parts'];
        if (parts is List && parts.isNotEmpty) {
          final buffer = StringBuffer();
          for (final p in parts) {
            if (p is Map && p['text'] is String) {
              buffer.write(p['text']);
            }
          }
          return buffer.toString();
        }
      }
    } catch (_) {}
    return null;
  }
}

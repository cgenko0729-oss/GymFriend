import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsService _settings;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _imagePromptCtrl;
  late final TextEditingController _textPromptCtrl;
  late final TextEditingController _mealPlanPromptCtrl;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsService>();
    _apiKeyCtrl = TextEditingController(text: _settings.apiKey);
    _modelCtrl = TextEditingController(text: _settings.modelId);
    _imagePromptCtrl = TextEditingController(text: _settings.imagePrompt);
    _textPromptCtrl = TextEditingController(text: _settings.textPrompt);
    _mealPlanPromptCtrl = TextEditingController(text: _settings.mealPlanPrompt);
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _imagePromptCtrl.dispose();
    _textPromptCtrl.dispose();
    _mealPlanPromptCtrl.dispose();
    super.dispose();
  }

  void _save() {
    _settings.apiKey = _apiKeyCtrl.text;
    _settings.modelId = _modelCtrl.text;
    _settings.imagePrompt = _imagePromptCtrl.text;
    _settings.textPrompt = _textPromptCtrl.text;
    _settings.mealPlanPrompt = _mealPlanPromptCtrl.text;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('設定を保存しました')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save, size: 20),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('🔑 APIキー (Google Gemini)'),
          const Text(
            'Google AI Studio で取得した Gemini APIキーを入力してください。'
            'キーと記録はこの端末内にのみ保存されます。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _apiKeyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              hintText: 'AIza...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscureKey ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 24),

          _sectionTitle('🤖 モデルID'),
          const Text(
            '使用する Gemini モデルのID。既定は最新の Gemini 3.1 Pro です。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              hintText: SettingsService.defaultModelId,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(
                  () => _modelCtrl.text = SettingsService.defaultModelId),
              child: const Text('既定に戻す'),
            ),
          ),
          const Divider(height: 40),

          _sectionTitle('✏️ プロンプト編集（微調整）'),
          const Text(
            'AIへの指示文を自由に編集できます。回答は日本語で返ります。\n'
            '※「SUMMARY:」の行は記録一覧の表示に使われるため、形式を保つことを推奨します。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),

          _promptField(
            label: '📷 画像分析プロンプト',
            controller: _imagePromptCtrl,
            onReset: () {
              _settings.resetImagePrompt();
              _imagePromptCtrl.text = _settings.imagePrompt;
            },
          ),
          const SizedBox(height: 20),

          _promptField(
            label: '📝 テキスト分析プロンプト（{food} が入力に置換されます）',
            controller: _textPromptCtrl,
            onReset: () {
              _settings.resetTextPrompt();
              _textPromptCtrl.text = _settings.textPrompt;
            },
          ),
          const SizedBox(height: 20),

          _promptField(
            label: '🍱 食事プラン生成プロンプト',
            controller: _mealPlanPromptCtrl,
            onReset: () {
              _settings.resetMealPlanPrompt();
              _mealPlanPromptCtrl.text = _settings.mealPlanPrompt;
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      );

  Widget _promptField({
    required String label,
    required TextEditingController controller,
    required VoidCallback onReset,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            TextButton.icon(
              onPressed: () {
                setState(onReset);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('デフォルトに戻しました（保存ボタンで確定）')),
                );
              },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('リセット'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          maxLines: 10,
          minLines: 4,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }
}

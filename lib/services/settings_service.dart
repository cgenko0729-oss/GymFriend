import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../prompts.dart';

/// アプリ設定（APIキー・モデルID・編集可能なプロンプト）を
/// ローカル(Hive)に保存・管理する。サーバーは一切使わない。
///
/// 設計方針: プロンプト/モデルIDは「デフォルトと異なる場合のみ」保存する。
/// これによりユーザーが編集していない項目は、アプリ更新で最新のデフォルトに
/// 自動追従する（編集済みの項目はそのまま保持される）。
class SettingsService extends ChangeNotifier {
  static const String boxName = 'settings';

  // Hive のキー
  static const String _kApiKey = 'gemini_api_key';
  static const String _kModelId = 'gemini_model_id';
  static const String _kImagePrompt = 'prompt_image';
  static const String _kTextPrompt = 'prompt_text';
  static const String _kMealPlanPrompt = 'prompt_meal_plan';
  static const String _kSchemaVersion = 'schema_version';

  /// 既定のモデルID（最新の Gemini 3.1 Pro）。設定画面で変更可能。
  static const String defaultModelId = 'gemini-3.1-pro-preview';

  /// 設定スキーマのバージョン。デフォルト値を変更したら上げる。
  static const int currentSchemaVersion = 2;

  final Box _box = Hive.box(boxName);

  SettingsService() {
    _migrate();
  }

  /// 旧バージョンで保存された「古いデフォルト値」を一度だけ掃除する。
  /// 未編集（=以前のデフォルトのまま保存されていた）の項目を消し、
  /// 最新のデフォルトに追従させる。
  void _migrate() {
    final stored = _box.get(_kSchemaVersion, defaultValue: 0) as int;
    if (stored >= currentSchemaVersion) return;

    // v1 以前は「保存時に全項目を書き込む」実装だったため、
    // 未編集でも古いデフォルトが保存されている可能性がある。
    // 安全のためプロンプト/モデルの上書き値を一旦クリアする。
    // （ユーザーがまだ本格的に微調整していない初期段階のための移行措置）
    _box.delete(_kImagePrompt);
    _box.delete(_kTextPrompt);
    _box.delete(_kMealPlanPrompt);

    final model = _box.get(_kModelId);
    if (model == null || model == 'gemini-3.1-pro' || model == '') {
      _box.delete(_kModelId);
    }

    _box.put(_kSchemaVersion, currentSchemaVersion);
  }

  /// 値がデフォルトと同じならキーを削除（=デフォルトに追従）、
  /// 異なるなら上書き値として保存する。
  void _putOrClear(String key, String value, String defaultValue) {
    if (value == defaultValue) {
      _box.delete(key);
    } else {
      _box.put(key, value);
    }
  }

  // ---- APIキー ----
  String get apiKey => _box.get(_kApiKey, defaultValue: '') as String;
  set apiKey(String value) {
    _box.put(_kApiKey, value.trim());
    notifyListeners();
  }

  bool get hasApiKey => apiKey.isNotEmpty;

  // ---- モデルID ----
  String get modelId =>
      _box.get(_kModelId, defaultValue: defaultModelId) as String;
  set modelId(String value) {
    final v = value.trim();
    _putOrClear(_kModelId, v.isEmpty ? defaultModelId : v, defaultModelId);
    notifyListeners();
  }

  // ---- プロンプト（編集可能 / 微調整可能）----
  String get imagePrompt =>
      _box.get(_kImagePrompt, defaultValue: DefaultPrompts.image) as String;
  set imagePrompt(String value) {
    _putOrClear(_kImagePrompt, value, DefaultPrompts.image);
    notifyListeners();
  }

  String get textPrompt =>
      _box.get(_kTextPrompt, defaultValue: DefaultPrompts.text) as String;
  set textPrompt(String value) {
    _putOrClear(_kTextPrompt, value, DefaultPrompts.text);
    notifyListeners();
  }

  String get mealPlanPrompt =>
      _box.get(_kMealPlanPrompt, defaultValue: DefaultPrompts.mealPlan)
          as String;
  set mealPlanPrompt(String value) {
    _putOrClear(_kMealPlanPrompt, value, DefaultPrompts.mealPlan);
    notifyListeners();
  }

  /// テキスト分析プロンプトに食べ物名を差し込む。
  /// {food} があれば置換、なければ末尾に追記する。
  String buildTextPrompt(String food) {
    final template = textPrompt;
    if (template.contains('{food}')) {
      return template.replaceAll('{food}', food);
    }
    return '$template\n\n対象の食べ物: $food';
  }

  // ---- リセット（上書き値を消してデフォルトに戻す）----
  void resetImagePrompt() {
    _box.delete(_kImagePrompt);
    notifyListeners();
  }

  void resetTextPrompt() {
    _box.delete(_kTextPrompt);
    notifyListeners();
  }

  void resetMealPlanPrompt() {
    _box.delete(_kMealPlanPrompt);
    notifyListeners();
  }
}

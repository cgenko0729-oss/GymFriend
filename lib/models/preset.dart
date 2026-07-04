import 'package:hive/hive.dart';

part 'preset.g.dart';

/// よく食べるものを登録しておく「プリセット」。
/// SUMMARY形式の文字列だけを保持し、栄養値の解析は Nutrition.parse に任せる。
@HiveType(typeId: 1)
class FoodPreset extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String summary; // "SUMMARY: 食べ物名 | kcal | protein | carbs | fat | sodium | 評価"

  @HiveField(2)
  final DateTime createdAt;

  FoodPreset({
    required this.id,
    required this.summary,
    required this.createdAt,
  });
}

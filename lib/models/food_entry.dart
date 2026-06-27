import 'package:hive/hive.dart';

part 'food_entry.g.dart';

@HiveType(typeId: 0)
class FoodEntry extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String imagePath; // 画像パス、または "MEAL_PLAN" / "" (テキストのみ)

  @HiveField(2)
  String fullResponse;

  @HiveField(3)
  String summary;

  @HiveField(4)
  final DateTime timestamp;

  @HiveField(5)
  List<String> chatHistory; // "user:質問" または "model:回答"

  FoodEntry({
    required this.id,
    required this.imagePath,
    required this.fullResponse,
    required this.summary,
    required this.timestamp,
    this.chatHistory = const [],
  });
}

/// SUMMARY 行から栄養情報を取り出すためのヘルパー。
///
/// 新形式(7項目):
///   SUMMARY: [食べ物名] | [カロリー]kcal | [タンパク質]g | [炭水化物]g | [脂質]g | [ナトリウム]mg | [評価]
/// 旧形式(4項目・後方互換):
///   SUMMARY: [食べ物名] | [カロリー]kcal | [タンパク質]g | [評価]
class Nutrition {
  final String foodName;
  final String rating;

  // 表示用の生テキスト（単位付き。例: "350kcal" "45g"）
  final String kcalRaw;
  final String proteinRaw;
  final String carbsRaw;
  final String fatRaw;
  final String sodiumRaw;

  // 集計用の数値
  final double kcal;
  final double protein;
  final double carbs;
  final double fat;
  final double sodium;

  /// 栄養データ（カロリー等）を解析できたか
  final bool hasData;

  const Nutrition({
    required this.foodName,
    required this.rating,
    required this.kcalRaw,
    required this.proteinRaw,
    required this.carbsRaw,
    required this.fatRaw,
    required this.sodiumRaw,
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.sodium,
    required this.hasData,
  });

  factory Nutrition.parse(String summary) {
    final cleaned = summary
        .replaceAll(RegExp(r'^SUMMARY:\s*', caseSensitive: false), '')
        .trim();
    final parts = cleaned.split('|').map((e) => e.trim()).toList();

    if (parts.length >= 7) {
      return Nutrition(
        foodName: parts[0],
        kcalRaw: parts[1],
        proteinRaw: parts[2],
        carbsRaw: parts[3],
        fatRaw: parts[4],
        sodiumRaw: parts[5],
        rating: parts[6],
        kcal: _num(parts[1]),
        protein: _num(parts[2]),
        carbs: _num(parts[3]),
        fat: _num(parts[4]),
        sodium: _num(parts[5]),
        hasData: true,
      );
    }

    if (parts.length >= 4) {
      // 旧形式: 名前 | カロリー | タンパク質 | 評価
      return Nutrition(
        foodName: parts[0],
        kcalRaw: parts[1],
        proteinRaw: parts[2],
        carbsRaw: '',
        fatRaw: '',
        sodiumRaw: '',
        rating: parts[3],
        kcal: _num(parts[1]),
        protein: _num(parts[2]),
        carbs: 0,
        fat: 0,
        sodium: 0,
        hasData: true,
      );
    }

    return Nutrition(
      foodName: cleaned.isEmpty ? '食事記録' : cleaned,
      rating: '',
      kcalRaw: '',
      proteinRaw: '',
      carbsRaw: '',
      fatRaw: '',
      sodiumRaw: '',
      kcal: 0,
      protein: 0,
      carbs: 0,
      fat: 0,
      sodium: 0,
      hasData: false,
    );
  }

  /// 文字列から最初の数値を取り出す（"350kcal" -> 350, "50-60g" -> 50,
  /// "-100kcal" -> -100  ※運動などカロリー消費を負の値で記録できるようにする）
  static double _num(String s) {
    final m = RegExp(r'(-?\d+(?:\.\d+)?)').firstMatch(s);
    if (m == null) return 0;
    return double.tryParse(m.group(1)!) ?? 0;
  }
}

/// 1日分の栄養合計
class DayTotals {
  double kcal = 0;
  double protein = 0;
  double carbs = 0;
  double fat = 0;
  double sodium = 0;
  int count = 0;

  void add(Nutrition n) {
    kcal += n.kcal;
    protein += n.protein;
    carbs += n.carbs;
    fat += n.fat;
    sodium += n.sodium;
    count++;
  }
}

/// 数値を見やすく整形（整数なら小数点なし）
String fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}

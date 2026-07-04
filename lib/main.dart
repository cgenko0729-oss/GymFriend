import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as path;
import 'package:gal/gal.dart';

import 'models/food_entry.dart';
import 'models/nutrition.dart';
import 'models/preset.dart';
import 'services/gemini_service.dart';
import 'services/settings_service.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initializeDateFormatting('ja_JP', null);

  await Hive.initFlutter();
  Hive.registerAdapter(FoodEntryAdapter());
  Hive.registerAdapter(FoodPresetAdapter());
  await Hive.openBox<FoodEntry>('food_entries');
  await Hive.openBox<FoodPreset>('food_presets');
  await Hive.openBox(SettingsService.boxName);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsService()),
        ChangeNotifierProvider(
            create: (ctx) => FoodProvider(ctx.read<SettingsService>())),
      ],
      child: MaterialApp(
        title: 'GymFriend',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class FoodProvider extends ChangeNotifier {
  final Box<FoodEntry> _box = Hive.box<FoodEntry>('food_entries');
  final Box<FoodPreset> _presetBox = Hive.box<FoodPreset>('food_presets');
  final SettingsService _settings;
  late final GeminiService _geminiService;
  bool _isLoading = false;

  FoodProvider(this._settings) {
    _geminiService = GeminiService(_settings);
  }

  bool get isLoading => _isLoading;
  List<FoodEntry> get entries =>
      _box.values.toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  // ---- プリセット（よく食べるものの登録）----
  List<FoodPreset> get presets => _presetBox.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  Future<void> savePreset(FoodEntry entry) async {
    final preset = FoodPreset(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      summary: entry.summary,
      createdAt: DateTime.now(),
    );
    await _presetBox.add(preset);
    notifyListeners();
  }

  Future<void> deletePreset(FoodPreset preset) async {
    await preset.delete();
    notifyListeners();
  }

  /// プリセットからAI分析なしで即座に記録を追加する。
  Future<FoodEntry> addFromPreset(FoodPreset preset) async {
    final foodName = Nutrition.parse(preset.summary).foodName;
    final note = 'プリセット「$foodName」から追加しました。';
    final entry = FoodEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      imagePath: '',
      fullResponse: note,
      summary: preset.summary,
      timestamp: DateTime.now(),
      chatHistory: ['model:$note'],
    );
    await _box.add(entry);
    notifyListeners();
    return entry;
  }

  // ---- 画像分析（ストリーミング）----
  Future<FoodEntry> analyzeImageStreamed(File image) async {
    // 画像をアプリ領域に保存
    final appDir = await getApplicationDocumentsDirectory();
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final savedImage = await image.copy(path.join(appDir.path, fileName));

    return _createAndStream(
      imagePath: savedImage.path,
      prompt: _settings.imagePrompt,
      image: savedImage,
      initialSummary: '分析中...',
    );
  }

  // ---- テキスト分析（ストリーミング）----
  Future<FoodEntry> analyzeTextStreamed(String text) async {
    return _createAndStream(
      imagePath: '',
      prompt: _settings.buildTextPrompt(text),
      initialSummary: '分析中...',
    );
  }

  // ---- 食事プラン生成（ストリーミング）----
  Future<FoodEntry> generateMealPlanStreamed() async {
    return _createAndStream(
      imagePath: 'MEAL_PLAN',
      prompt: _settings.mealPlanPrompt,
      initialSummary: '食事プラン',
      isMealPlan: true,
    );
  }

  Future<FoodEntry> _createAndStream({
    required String imagePath,
    required String prompt,
    File? image,
    required String initialSummary,
    bool isMealPlan = false,
  }) async {
    final entry = FoodEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      imagePath: imagePath,
      fullResponse: '',
      summary: initialSummary,
      timestamp: DateTime.now(),
      chatHistory: ['model:分析中...'],
    );
    await _box.add(entry);
    notifyListeners();

    _streamInitial(entry, prompt, image, isMealPlan);
    return entry;
  }

  Future<void> _streamInitial(
      FoodEntry entry, String prompt, File? image, bool isMealPlan) async {
    String fullText = '';
    try {
      await for (final chunk
          in _geminiService.chatStream(prompt, [], image: image)) {
        fullText += chunk;
        entry.chatHistory.last = 'model:$fullText';
        notifyListeners();
      }

      entry.fullResponse = fullText;
      if (isMealPlan) {
        entry.summary = '食事プラン';
      } else {
        entry.summary = _extractSummary(fullText);
      }
      await entry.save();
      notifyListeners();
    } catch (e) {
      entry.chatHistory.last = 'model:分析に失敗しました: $e';
      entry.summary = 'エラー';
      await entry.save();
      notifyListeners();
    }
  }

  // ---- 追問（フォローアップ会話）----
  Future<void> sendChatMessage(FoodEntry entry, String message) async {
    _isLoading = true;
    notifyListeners();

    entry.chatHistory.add('user:$message');
    await entry.save();
    notifyListeners();

    try {
      final historyToSend =
          entry.chatHistory.take(entry.chatHistory.length - 1).toList();

      File? imageFile;
      if (entry.imagePath.isNotEmpty && entry.imagePath != 'MEAL_PLAN') {
        imageFile = File(entry.imagePath);
      }

      entry.chatHistory.add('model:');
      notifyListeners();

      String fullResponse = '';
      await for (final chunk in _geminiService
          .chatStream(message, historyToSend, image: imageFile)) {
        fullResponse += chunk;
        entry.chatHistory.last = 'model:$fullResponse';
        notifyListeners();
      }
      await entry.save();
    } catch (e) {
      entry.chatHistory.add('model:エラー: AIに接続できません ($e)');
      await entry.save();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // ---- 記録の編集（日付・名前・栄養値・評価）----
  Future<void> updateEntry(
    FoodEntry entry, {
    required DateTime timestamp,
    required String summary,
  }) async {
    entry.timestamp = timestamp;
    entry.summary = summary;
    await entry.save();
    notifyListeners();
  }

  Future<void> deleteEntry(FoodEntry entry) async {
    if (entry.imagePath.isNotEmpty && entry.imagePath != 'MEAL_PLAN') {
      try {
        final f = File(entry.imagePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await entry.delete();
    notifyListeners();
  }

  String _extractSummary(String response) {
    final RegExp summaryRegex = RegExp(
        r'(?:^|\n)(?:\*\*)?SUMMARY(?:\*\*)?:\s*(.+)$',
        caseSensitive: false,
        multiLine: true);
    final match = summaryRegex.firstMatch(response);
    if (match != null) {
      return 'SUMMARY: ${match.group(1)!.trim()}';
    }
    final RegExp pipeRegex = RegExp(
        r'(?:^|\n)([^|\n]+\|[^|\n]+\|[^|\n]+\|[^|\n]+)(?:$|\n)',
        multiLine: true);
    final pipeMatch = pipeRegex.firstMatch(response);
    if (pipeMatch != null) {
      return 'SUMMARY: ${pipeMatch.group(1)!.trim()}';
    }
    return '分析完了';
  }
}

/// 一覧の「その日の合計」ヘッダー行を表すデータ。
class _DayHeaderRow {
  final DateTime date;
  final DayTotals totals;
  _DayHeaderRow({required this.date, required this.totals});
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime? _selectedMonth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GymFriend 記録'),
        centerTitle: true,
        actions: [
          Consumer<FoodProvider>(
            builder: (context, provider, child) {
              final months = provider.entries
                  .map((e) => DateTime(e.timestamp.year, e.timestamp.month))
                  .toSet()
                  .toList()
                ..sort((a, b) => b.compareTo(a));

              return PopupMenuButton<DateTime?>(
                icon: const Icon(Icons.filter_list),
                tooltip: '月で絞り込み',
                onSelected: (date) => setState(() => _selectedMonth = date),
                itemBuilder: (context) {
                  return [
                    const PopupMenuItem<DateTime?>(
                      value: null,
                      child: Text('すべて表示'),
                    ),
                    ...months.map((date) {
                      return PopupMenuItem<DateTime?>(
                        value: date,
                        child:
                            Text(DateFormat('yyyy年 MM月', 'ja_JP').format(date)),
                      );
                    }),
                  ];
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '設定',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 8.0),
            child: FilledButton.icon(
              onPressed: () => _generateMealPlan(context),
              icon: const Icon(Icons.restaurant_menu, size: 20),
              label: const Text('食事プラン'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.deepOrange.shade50,
                foregroundColor: Colors.deepOrange,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Consumer<FoodProvider>(
        builder: (context, provider, child) {
          final filteredEntries = _selectedMonth == null
              ? provider.entries
              : provider.entries.where((e) {
                  return e.timestamp.year == _selectedMonth!.year &&
                      e.timestamp.month == _selectedMonth!.month;
                }).toList();

          if (filteredEntries.isEmpty) {
            if (provider.entries.isEmpty) {
              return _buildEmptyState(context);
            } else {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('この月の記録はありません'),
                    TextButton(
                      onPressed: () => setState(() => _selectedMonth = null),
                      child: const Text('すべて表示'),
                    )
                  ],
                ),
              );
            }
          }
          final rows = _buildRows(filteredEntries);
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              if (row is _DayHeaderRow) {
                return _buildDayHeader(row);
              }
              return _buildEntryCard(context, row as FoodEntry);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_food_btn',
        onPressed: () => _showImageSourceDialog(context),
        label: const Text('食事を追加'),
        icon: const Icon(Icons.add_a_photo),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final hasKey = context.watch<SettingsService>().hasApiKey;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.fitness_center, size: 64, color: Colors.deepOrange),
          const SizedBox(height: 16),
          const Text('まだ記録がありません',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (!hasKey) ...[
            const Text('まず設定でAPIキーを入力してください',
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              icon: const Icon(Icons.settings),
              label: const Text('設定を開く'),
            ),
          ] else
            const Text('右下のボタンから食事を追加しましょう！',
                style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  /// 記録を日付ごとにグループ化し、各日の先頭に合計ヘッダー行を挿入する。
  /// entries は新しい順に並んでいる前提。
  List<Object> _buildRows(List<FoodEntry> entries) {
    final Map<String, List<FoodEntry>> byDay = {};
    for (final e in entries) {
      final key = DateFormat('yyyy-MM-dd').format(e.timestamp);
      byDay.putIfAbsent(key, () => []).add(e);
    }

    final rows = <Object>[];
    byDay.forEach((key, dayEntries) {
      final totals = DayTotals();
      for (final e in dayEntries) {
        if (e.imagePath == 'MEAL_PLAN') continue;
        final n = Nutrition.parse(e.summary);
        if (n.hasData) totals.add(n);
      }
      rows.add(_DayHeaderRow(date: dayEntries.first.timestamp, totals: totals));
      rows.addAll(dayEntries);
    });
    return rows;
  }

  Widget _buildDayHeader(_DayHeaderRow row) {
    final t = row.totals;
    final dateStr = DateFormat('M月d日 (E)', 'ja_JP').format(row.date);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.deepOrange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepOrange.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today,
                  size: 16, color: Colors.deepOrange),
              const SizedBox(width: 6),
              Text(
                dateStr,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.deepOrange),
              ),
              const Spacer(),
              Text(
                '${t.count}食 合計',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
            ],
          ),
          if (t.count > 0) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _totalChip('🔥', '${fmtNum(t.kcal)}kcal'),
                _totalChip('🥩', 'たんぱく質 ${fmtNum(t.protein)}g'),
                _totalChip('🍚', '炭水化物 ${fmtNum(t.carbs)}g'),
                _totalChip('🧈', '脂質 ${fmtNum(t.fat)}g'),
                _totalChip('🧂', 'ナトリウム ${fmtNum(t.sodium)}mg'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _totalChip(String icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 3),
        Text(
          text,
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
        ),
      ],
    );
  }

  Widget _buildEntryCard(BuildContext context, FoodEntry entry) {
    final bool isMealPlan = entry.imagePath == 'MEAL_PLAN';
    final Nutrition n = Nutrition.parse(entry.summary);

    final String foodName = isMealPlan ? '1日の食事プラン' : n.foodName;
    final String rating = isMealPlan ? '' : n.rating;

    // カードに表示する栄養テキスト（存在する項目のみ）
    final macroParts = <String>[];
    if (!isMealPlan && n.hasData) {
      if (n.kcalRaw.isNotEmpty) macroParts.add('🔥${n.kcalRaw}');
      if (n.proteinRaw.isNotEmpty) {
        macroParts.add('たんぱく質 ${n.proteinRaw}');
      }
      if (n.carbsRaw.isNotEmpty) macroParts.add('炭水化物 ${n.carbsRaw}');
      if (n.fatRaw.isNotEmpty) macroParts.add('脂質 ${n.fatRaw}');
      if (n.sodiumRaw.isNotEmpty) macroParts.add('ナトリウム ${n.sodiumRaw}');
    }
    final String macroText = macroParts.join('  ｜ ');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
        ),
        onLongPress: () => _showEntryActions(context, entry),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: entry.imagePath == 'MEAL_PLAN'
                    ? Container(
                        width: 70,
                        height: 70,
                        color: Colors.deepOrange.shade100,
                        child: const Icon(Icons.restaurant_menu,
                            color: Colors.deepOrange, size: 30),
                      )
                    : entry.imagePath.isEmpty
                        ? Container(
                            width: 70,
                            height: 70,
                            color: Colors.blueGrey.shade100,
                            child: const Icon(Icons.edit_note,
                                color: Colors.blueGrey, size: 30),
                          )
                        : Image.file(
                            File(entry.imagePath),
                            width: 70,
                            height: 70,
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, s) =>
                                const Icon(Icons.broken_image),
                          ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            DateFormat('MM月dd日 a h時mm分  yyyy年', 'ja_JP')
                                .format(entry.timestamp),
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ),
                        if (rating.isNotEmpty && !isMealPlan)
                          Text(
                            rating,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _getVerdictColor(rating),
                              fontSize: 12.5,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      foodName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _getVerdictColor(rating) != Colors.grey
                            ? _getVerdictColor(rating)
                            : Colors.black87,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (macroText.isNotEmpty)
                      Text(
                        macroText,
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade700),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEntryActions(BuildContext context, FoodEntry entry) {
    final bool isMealPlan = entry.imagePath == 'MEAL_PLAN';
    final bool hasData = Nutrition.parse(entry.summary).hasData;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('編集'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  showDialog(
                    context: context,
                    builder: (_) => _EditEntryDialog(entry: entry),
                  );
                },
              ),
              if (!isMealPlan && hasData)
                ListTile(
                  leading: const Icon(Icons.bookmark_add_outlined),
                  title: const Text('プリセットとして保存'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Provider.of<FoodProvider>(context, listen: false)
                        .savePreset(entry);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('プリセットに保存しました')),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('削除', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmDelete(context, entry);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, FoodEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('記録を削除'),
        content: const Text('この記録を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Provider.of<FoodProvider>(context, listen: false)
                  .deleteEntry(entry);
              Navigator.pop(ctx);
            },
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showImageSourceDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('食べ物の名前を入力'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (!_ensureApiKey(context)) return;
                  _showTextInputDialog(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('写真を撮る'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (!_ensureApiKey(context)) return;
                  _pickImage(context, ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('アルバムから選ぶ'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (!_ensureApiKey(context)) return;
                  _pickImage(context, ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.bookmark),
                title: const Text('プリセットから選ぶ'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showPresetPicker(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPresetPicker(BuildContext context) {
    final presets = context.read<FoodProvider>().presets;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        if (presets.isEmpty) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: Text(
                '保存されたプリセットはありません。\n記録を長押しして「プリセットとして保存」で登録できます。',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: presets.length,
              itemBuilder: (context, index) {
                final preset = presets[index];
                final n = Nutrition.parse(preset.summary);
                final macroParts = <String>[];
                if (n.kcalRaw.isNotEmpty) macroParts.add('🔥${n.kcalRaw}');
                if (n.proteinRaw.isNotEmpty) {
                  macroParts.add('たんぱく質 ${n.proteinRaw}');
                }
                return ListTile(
                  leading: const Icon(Icons.bookmark, color: Colors.deepOrange),
                  title: Text(n.foodName),
                  subtitle: macroParts.isEmpty
                      ? null
                      : Text(macroParts.join('  ｜ '),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey),
                    onPressed: () {
                      Provider.of<FoodProvider>(context, listen: false)
                          .deletePreset(preset);
                      Navigator.pop(sheetContext);
                    },
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final provider =
                        Provider.of<FoodProvider>(context, listen: false);
                    final entry = await provider.addFromPreset(preset);
                    if (!context.mounted) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  bool _ensureApiKey(BuildContext context) {
    final settings = context.read<SettingsService>();
    if (!settings.hasApiKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('先に設定でAPIキーを入力してください'),
          action: SnackBarAction(
            label: '設定',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ),
      );
      return false;
    }
    return true;
  }

  void _showTextInputDialog(BuildContext context) {
    final TextEditingController textController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('食べ物の名前を入力'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(hintText: '例：鶏胸肉とブロッコリー'),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () {
                if (textController.text.isNotEmpty) {
                  Navigator.pop(context);
                  _startTextAnalysis(context, textController.text);
                }
              },
              child: const Text('分析'),
            ),
          ],
        );
      },
    );
  }

  void _generateMealPlan(BuildContext context) async {
    if (!_ensureApiKey(context)) return;
    final provider = Provider.of<FoodProvider>(context, listen: false);
    final entry = await provider.generateMealPlanStreamed();
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
    );
  }

  void _startTextAnalysis(BuildContext context, String text) async {
    final provider = Provider.of<FoodProvider>(context, listen: false);
    final entry = await provider.analyzeTextStreamed(text);
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
    );
  }

  Future<void> _pickImage(BuildContext context, ImageSource source) async {
    try {
      final picker = ImagePicker();
      final pickedFile =
          await picker.pickImage(source: source, imageQuality: 70);

      if (pickedFile != null) {
        if (source == ImageSource.camera && await Gal.hasAccess()) {
          try {
            await Gal.putImage(pickedFile.path);
          } catch (e) {
            debugPrint('ギャラリー保存に失敗: $e');
          }
        }
        if (context.mounted) {
          final provider = Provider.of<FoodProvider>(context, listen: false);
          final entry =
              await provider.analyzeImageStreamed(File(pickedFile.path));
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('画像の取得に失敗しました: $e')),
        );
      }
    }
  }

  Color _getVerdictColor(String verdict) {
    switch (verdict.trim()) {
      case '最高':
      case '良い':
        return Colors.green;
      case '普通':
      case '注意':
        return Colors.orange;
      case '避けるべき':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

/// 記録編集ダイアログ。日付・食べ物名・栄養値・評価を編集できる。
/// 食事プラン記録は日付のみ編集可能（栄養項目は表示しない）。
class _EditEntryDialog extends StatefulWidget {
  final FoodEntry entry;

  const _EditEntryDialog({required this.entry});

  @override
  State<_EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends State<_EditEntryDialog> {
  static const List<String> _ratings = ['最高', '良い', '普通', '注意', '避けるべき'];

  late final bool _isMealPlan;
  late DateTime _dateTime;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _kcalCtrl;
  late final TextEditingController _proteinCtrl;
  late final TextEditingController _carbsCtrl;
  late final TextEditingController _fatCtrl;
  late final TextEditingController _sodiumCtrl;
  late String _rating;

  @override
  void initState() {
    super.initState();
    _isMealPlan = widget.entry.imagePath == 'MEAL_PLAN';
    final n = Nutrition.parse(widget.entry.summary);
    _dateTime = widget.entry.timestamp;
    _nameCtrl = TextEditingController(text: n.foodName);
    _kcalCtrl = TextEditingController(
        text: n.kcalRaw.isEmpty ? '' : fmtNum(n.kcal));
    _proteinCtrl = TextEditingController(
        text: n.proteinRaw.isEmpty ? '' : fmtNum(n.protein));
    _carbsCtrl = TextEditingController(
        text: n.carbsRaw.isEmpty ? '' : fmtNum(n.carbs));
    _fatCtrl =
        TextEditingController(text: n.fatRaw.isEmpty ? '' : fmtNum(n.fat));
    _sodiumCtrl = TextEditingController(
        text: n.sodiumRaw.isEmpty ? '' : fmtNum(n.sodium));
    _rating = _ratings.contains(n.rating) ? n.rating : '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _kcalCtrl.dispose();
    _proteinCtrl.dispose();
    _carbsCtrl.dispose();
    _fatCtrl.dispose();
    _sodiumCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dateTime,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dateTime),
    );
    if (time == null) return;

    setState(() {
      _dateTime = DateTime(
          date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  double _parseOrZero(String text) => double.tryParse(text.trim()) ?? 0;

  void _save() {
    final provider = Provider.of<FoodProvider>(context, listen: false);

    if (_isMealPlan) {
      provider.updateEntry(
        widget.entry,
        timestamp: _dateTime,
        summary: widget.entry.summary,
      );
      Navigator.pop(context);
      return;
    }

    final name = _nameCtrl.text.trim().isEmpty
        ? '食事記録'
        : _nameCtrl.text.trim();
    final kcal = fmtNum(_parseOrZero(_kcalCtrl.text));
    final protein = fmtNum(_parseOrZero(_proteinCtrl.text));
    final carbs = fmtNum(_parseOrZero(_carbsCtrl.text));
    final fat = fmtNum(_parseOrZero(_fatCtrl.text));
    final sodium = fmtNum(_parseOrZero(_sodiumCtrl.text));

    final summary =
        'SUMMARY: $name | ${kcal}kcal | ${protein}g | ${carbs}g | ${fat}g | ${sodium}mg | $_rating';

    provider.updateEntry(widget.entry, timestamp: _dateTime, summary: summary);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('記録を編集'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              onPressed: _pickDateTime,
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text(
                  DateFormat('yyyy/MM/dd HH:mm', 'ja_JP').format(_dateTime)),
            ),
            if (!_isMealPlan) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: '食べ物名'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _kcalCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      decoration: const InputDecoration(
                        labelText: 'カロリー(kcal)',
                        hintText: '運動などは -100 のように入力',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _proteinCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'タンパク質(g)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _carbsCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                          labelText: '炭水化物(g)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _fatCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(labelText: '脂質(g)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _sodiumCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'ナトリウム(mg)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _rating,
                decoration: const InputDecoration(labelText: '評価'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('なし')),
                  ..._ratings.map(
                      (r) => DropdownMenuItem(value: r, child: Text(r))),
                ],
                onChanged: (v) => setState(() => _rating = v ?? ''),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class DetailScreen extends StatefulWidget {
  final FoodEntry entry;

  const DetailScreen({super.key, required this.entry});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  double _textSize = 18.0;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<FoodProvider>(context);

    List<Widget> chatWidgets = [
      widget.entry.imagePath == 'MEAL_PLAN'
          ? Container(
              width: double.infinity,
              height: 150,
              color: Colors.deepOrange.shade50,
              child: const Center(
                  child: Icon(Icons.restaurant_menu,
                      size: 80, color: Colors.deepOrange)),
            )
          : widget.entry.imagePath.isEmpty
              ? Container(
                  width: double.infinity,
                  height: 150,
                  color: Colors.blueGrey.shade50,
                  child: const Center(
                      child: Icon(Icons.edit_note,
                          size: 80, color: Colors.blueGrey)),
                )
              : Image.file(
                  File(widget.entry.imagePath),
                  width: double.infinity,
                  height: 250,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox(
                    height: 250,
                    child: Center(child: Icon(Icons.broken_image, size: 50)),
                  ),
                ),
    ];

    if (widget.entry.chatHistory.isEmpty &&
        widget.entry.fullResponse.isNotEmpty) {
      chatWidgets
          .add(_buildMessageBubble(widget.entry.fullResponse, isUser: false));
    }

    for (var msg in widget.entry.chatHistory) {
      if (msg.startsWith('user:')) {
        chatWidgets.add(_buildMessageBubble(msg.substring(5), isUser: true));
      } else if (msg.startsWith('model:')) {
        chatWidgets.add(_buildMessageBubble(msg.substring(6), isUser: false));
      }
    }

    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(
        title: const Text('分析と対話'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50.0),
          child: Container(
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                const Text('文字サイズ: ',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Icon(Icons.text_fields, size: 16),
                Expanded(
                  child: Slider(
                    value: _textSize,
                    min: 14.0,
                    max: 34.0,
                    divisions: 10,
                    activeColor: Colors.deepOrange,
                    label: _textSize.round().toString(),
                    onChanged: (val) => setState(() => _textSize = val),
                  ),
                ),
                const Icon(Icons.text_fields, size: 28),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Column(children: chatWidgets),
            ),
          ),
          if (provider.isLoading) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: TextStyle(fontSize: _textSize),
                    decoration: const InputDecoration(
                      hintText: 'もっと質問する？',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: provider.isLoading
                      ? null
                      : () {
                          if (_controller.text.isNotEmpty) {
                            final text = _controller.text;
                            _controller.clear();
                            provider.sendChatMessage(widget.entry, text);
                          }
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(String text, {required bool isUser}) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? Colors.deepOrange.shade100 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: isUser
            ? Text(text, style: TextStyle(fontSize: _textSize))
            : MarkdownBody(
                data: text,
                selectable: true,
                styleSheet:
                    MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: TextStyle(fontSize: _textSize),
                  h1: TextStyle(
                      fontSize: _textSize + 8, fontWeight: FontWeight.bold),
                  h2: TextStyle(
                      fontSize: _textSize + 6, fontWeight: FontWeight.bold),
                  h3: TextStyle(
                      fontSize: _textSize + 4, fontWeight: FontWeight.bold),
                  h4: TextStyle(
                      fontSize: _textSize + 2, fontWeight: FontWeight.bold),
                  h5: TextStyle(
                      fontSize: _textSize + 1, fontWeight: FontWeight.bold),
                  h6: TextStyle(
                      fontSize: _textSize, fontWeight: FontWeight.bold),
                  listBullet: TextStyle(fontSize: _textSize),
                  strong: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: _textSize),
                  em: TextStyle(
                      fontStyle: FontStyle.italic, fontSize: _textSize),
                ),
              ),
      ),
    );
  }
}

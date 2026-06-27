// GENERATED-STYLE ADAPTER (hand-written to match hive_generator output)

part of 'food_entry.dart';

class FoodEntryAdapter extends TypeAdapter<FoodEntry> {
  @override
  final int typeId = 0;

  @override
  FoodEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FoodEntry(
      id: fields[0] as String,
      imagePath: fields[1] as String,
      fullResponse: fields[2] as String,
      summary: fields[3] as String,
      timestamp: fields[4] as DateTime,
      chatHistory: (fields[5] as List).cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, FoodEntry obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.imagePath)
      ..writeByte(2)
      ..write(obj.fullResponse)
      ..writeByte(3)
      ..write(obj.summary)
      ..writeByte(4)
      ..write(obj.timestamp)
      ..writeByte(5)
      ..write(obj.chatHistory);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FoodEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

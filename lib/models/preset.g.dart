// GENERATED-STYLE ADAPTER (hand-written to match hive_generator output)

part of 'preset.dart';

class FoodPresetAdapter extends TypeAdapter<FoodPreset> {
  @override
  final int typeId = 1;

  @override
  FoodPreset read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FoodPreset(
      id: fields[0] as String,
      summary: fields[1] as String,
      createdAt: fields[2] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, FoodPreset obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.summary)
      ..writeByte(2)
      ..write(obj.createdAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FoodPresetAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

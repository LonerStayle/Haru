// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'category.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Category _$CategoryFromJson(Map<String, dynamic> json) => _Category(
  id: json['id'] as String,
  label: json['label'] as String,
  iconCodePoint: (json['iconCodePoint'] as num).toInt(),
  colorValue: (json['colorValue'] as num).toInt(),
  sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
  isBuiltin: json['isBuiltin'] as bool? ?? false,
  groupId: json['groupId'] as String? ?? null,
  archived: json['archived'] as bool? ?? false,
);

Map<String, dynamic> _$CategoryToJson(_Category instance) => <String, dynamic>{
  'id': instance.id,
  'label': instance.label,
  'iconCodePoint': instance.iconCodePoint,
  'colorValue': instance.colorValue,
  'sortOrder': instance.sortOrder,
  'isBuiltin': instance.isBuiltin,
  'groupId': instance.groupId,
  'archived': instance.archived,
};

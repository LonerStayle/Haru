// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'group.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Group _$GroupFromJson(Map<String, dynamic> json) => _Group(
  id: json['id'] as String,
  label: json['label'] as String,
  colorValue: (json['colorValue'] as num).toInt(),
  sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
  isBuiltin: json['isBuiltin'] as bool? ?? false,
  archived: json['archived'] as bool? ?? false,
);

Map<String, dynamic> _$GroupToJson(_Group instance) => <String, dynamic>{
  'id': instance.id,
  'label': instance.label,
  'colorValue': instance.colorValue,
  'sortOrder': instance.sortOrder,
  'isBuiltin': instance.isBuiltin,
  'archived': instance.archived,
};

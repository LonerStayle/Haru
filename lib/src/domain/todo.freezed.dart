// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'todo.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Todo {

 String get id; String get title;@JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson) Category get category; DateTime? get dueAt; DateTime? get doneAt;// 진행중(in-progress) 시작 시각. 값이 있고 doneAt 이 null 이면 "진행중" 상태.
// 완료(doneAt set) 시엔 null 로 비워진다. (note 는 항상 null.)
 DateTime? get startedAt; DateTime get createdAt; DateTime get updatedAt; String? get calendarEventId;// [calendarId] — calendarEventId 가 속한 Google Calendar id. null = 미등록
// 또는 레거시(과거엔 'primary' 하드코딩이었으므로 null 이면 primary 로 간주).
 String? get calendarId;// [calendarOrigin] — 'app'(앱에서 만든 할 일) | 'gcal'(Google Calendar 에서
// 유입된 할 일). **삭제 규칙의 유일한 근거**: 구글 캘린더 쪽 이벤트가 삭제됐을 때
// origin='app' 이면 할 일은 남기고 캘린더 연결만 해제, origin='gcal' 이면 할 일도
// 함께 삭제한다. 반드시 Supabase 로 전파되어 macOS/Android 양쪽이 같은 판단을 한다.
 String get calendarOrigin; String? get parentId; TodoType get type; int get sortOrder;// v1.2 — 상세 메모 (long text). nullable + 누락 시 null 로 안전 fallback.
 String? get description;// ── 날짜·기간 모델 (fast-tasks 4/5/1) — dueAt 은 앵커로 그대로 유지 ──────────
// [endAt] — 기간 모드의 종료 시각. 단일 모드면 null.
 DateTime? get endAt;// [isAllDay] — true 면 시간 미표시 (화면 어디에도 00:00 을 찍지 않음).
 bool get isAllDay;// [timeAnchor] — 단일·시간 모드에서 dueAt 이 '시작'('start')인지 '마감'('end')인지.
// 하루종일·기간 모드에서는 의미 없음 (기본 'start' 유지).
 String get timeAnchor;// ── 날짜 반복 (date-repeat) ─────────────────────────────────────────────
// [seriesId] — 소속 반복 시리즈 id. 마스터는 자기 id, 인스턴스는 마스터 id.
//   null = 일반(비반복) Todo.
 String? get seriesId;// [recurrenceRule] — 반복 규칙 직렬화(RecurrenceRule.encode). **마스터에만** 채움.
 String? get recurrenceRule;// [recurrenceEndAt] — 반복 종료일. **마스터에만**. null = 무한.
 DateTime? get recurrenceEndAt;// [isSeriesMaster] — true = 규칙 보유 숨김 템플릿(모든 목록에서 제외, 캘린더 RRULE 소유).
 bool get isSeriesMaster;
/// Create a copy of Todo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TodoCopyWith<Todo> get copyWith => _$TodoCopyWithImpl<Todo>(this as Todo, _$identity);

  /// Serializes this Todo to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Todo&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&(identical(other.dueAt, dueAt) || other.dueAt == dueAt)&&(identical(other.doneAt, doneAt) || other.doneAt == doneAt)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.calendarEventId, calendarEventId) || other.calendarEventId == calendarEventId)&&(identical(other.calendarId, calendarId) || other.calendarId == calendarId)&&(identical(other.calendarOrigin, calendarOrigin) || other.calendarOrigin == calendarOrigin)&&(identical(other.parentId, parentId) || other.parentId == parentId)&&(identical(other.type, type) || other.type == type)&&(identical(other.sortOrder, sortOrder) || other.sortOrder == sortOrder)&&(identical(other.description, description) || other.description == description)&&(identical(other.endAt, endAt) || other.endAt == endAt)&&(identical(other.isAllDay, isAllDay) || other.isAllDay == isAllDay)&&(identical(other.timeAnchor, timeAnchor) || other.timeAnchor == timeAnchor)&&(identical(other.seriesId, seriesId) || other.seriesId == seriesId)&&(identical(other.recurrenceRule, recurrenceRule) || other.recurrenceRule == recurrenceRule)&&(identical(other.recurrenceEndAt, recurrenceEndAt) || other.recurrenceEndAt == recurrenceEndAt)&&(identical(other.isSeriesMaster, isSeriesMaster) || other.isSeriesMaster == isSeriesMaster));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,title,category,dueAt,doneAt,startedAt,createdAt,updatedAt,calendarEventId,calendarId,calendarOrigin,parentId,type,sortOrder,description,endAt,isAllDay,timeAnchor,seriesId,recurrenceRule,recurrenceEndAt,isSeriesMaster]);

@override
String toString() {
  return 'Todo(id: $id, title: $title, category: $category, dueAt: $dueAt, doneAt: $doneAt, startedAt: $startedAt, createdAt: $createdAt, updatedAt: $updatedAt, calendarEventId: $calendarEventId, calendarId: $calendarId, calendarOrigin: $calendarOrigin, parentId: $parentId, type: $type, sortOrder: $sortOrder, description: $description, endAt: $endAt, isAllDay: $isAllDay, timeAnchor: $timeAnchor, seriesId: $seriesId, recurrenceRule: $recurrenceRule, recurrenceEndAt: $recurrenceEndAt, isSeriesMaster: $isSeriesMaster)';
}


}

/// @nodoc
abstract mixin class $TodoCopyWith<$Res>  {
  factory $TodoCopyWith(Todo value, $Res Function(Todo) _then) = _$TodoCopyWithImpl;
@useResult
$Res call({
 String id, String title,@JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson) Category category, DateTime? dueAt, DateTime? doneAt, DateTime? startedAt, DateTime createdAt, DateTime updatedAt, String? calendarEventId, String? calendarId, String calendarOrigin, String? parentId, TodoType type, int sortOrder, String? description, DateTime? endAt, bool isAllDay, String timeAnchor, String? seriesId, String? recurrenceRule, DateTime? recurrenceEndAt, bool isSeriesMaster
});


$CategoryCopyWith<$Res> get category;

}
/// @nodoc
class _$TodoCopyWithImpl<$Res>
    implements $TodoCopyWith<$Res> {
  _$TodoCopyWithImpl(this._self, this._then);

  final Todo _self;
  final $Res Function(Todo) _then;

/// Create a copy of Todo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? category = null,Object? dueAt = freezed,Object? doneAt = freezed,Object? startedAt = freezed,Object? createdAt = null,Object? updatedAt = null,Object? calendarEventId = freezed,Object? calendarId = freezed,Object? calendarOrigin = null,Object? parentId = freezed,Object? type = null,Object? sortOrder = null,Object? description = freezed,Object? endAt = freezed,Object? isAllDay = null,Object? timeAnchor = null,Object? seriesId = freezed,Object? recurrenceRule = freezed,Object? recurrenceEndAt = freezed,Object? isSeriesMaster = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as Category,dueAt: freezed == dueAt ? _self.dueAt : dueAt // ignore: cast_nullable_to_non_nullable
as DateTime?,doneAt: freezed == doneAt ? _self.doneAt : doneAt // ignore: cast_nullable_to_non_nullable
as DateTime?,startedAt: freezed == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,calendarEventId: freezed == calendarEventId ? _self.calendarEventId : calendarEventId // ignore: cast_nullable_to_non_nullable
as String?,calendarId: freezed == calendarId ? _self.calendarId : calendarId // ignore: cast_nullable_to_non_nullable
as String?,calendarOrigin: null == calendarOrigin ? _self.calendarOrigin : calendarOrigin // ignore: cast_nullable_to_non_nullable
as String,parentId: freezed == parentId ? _self.parentId : parentId // ignore: cast_nullable_to_non_nullable
as String?,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as TodoType,sortOrder: null == sortOrder ? _self.sortOrder : sortOrder // ignore: cast_nullable_to_non_nullable
as int,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,endAt: freezed == endAt ? _self.endAt : endAt // ignore: cast_nullable_to_non_nullable
as DateTime?,isAllDay: null == isAllDay ? _self.isAllDay : isAllDay // ignore: cast_nullable_to_non_nullable
as bool,timeAnchor: null == timeAnchor ? _self.timeAnchor : timeAnchor // ignore: cast_nullable_to_non_nullable
as String,seriesId: freezed == seriesId ? _self.seriesId : seriesId // ignore: cast_nullable_to_non_nullable
as String?,recurrenceRule: freezed == recurrenceRule ? _self.recurrenceRule : recurrenceRule // ignore: cast_nullable_to_non_nullable
as String?,recurrenceEndAt: freezed == recurrenceEndAt ? _self.recurrenceEndAt : recurrenceEndAt // ignore: cast_nullable_to_non_nullable
as DateTime?,isSeriesMaster: null == isSeriesMaster ? _self.isSeriesMaster : isSeriesMaster // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}
/// Create a copy of Todo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$CategoryCopyWith<$Res> get category {
  
  return $CategoryCopyWith<$Res>(_self.category, (value) {
    return _then(_self.copyWith(category: value));
  });
}
}


/// Adds pattern-matching-related methods to [Todo].
extension TodoPatterns on Todo {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Todo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Todo() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Todo value)  $default,){
final _that = this;
switch (_that) {
case _Todo():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Todo value)?  $default,){
final _that = this;
switch (_that) {
case _Todo() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title, @JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson)  Category category,  DateTime? dueAt,  DateTime? doneAt,  DateTime? startedAt,  DateTime createdAt,  DateTime updatedAt,  String? calendarEventId,  String? calendarId,  String calendarOrigin,  String? parentId,  TodoType type,  int sortOrder,  String? description,  DateTime? endAt,  bool isAllDay,  String timeAnchor,  String? seriesId,  String? recurrenceRule,  DateTime? recurrenceEndAt,  bool isSeriesMaster)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Todo() when $default != null:
return $default(_that.id,_that.title,_that.category,_that.dueAt,_that.doneAt,_that.startedAt,_that.createdAt,_that.updatedAt,_that.calendarEventId,_that.calendarId,_that.calendarOrigin,_that.parentId,_that.type,_that.sortOrder,_that.description,_that.endAt,_that.isAllDay,_that.timeAnchor,_that.seriesId,_that.recurrenceRule,_that.recurrenceEndAt,_that.isSeriesMaster);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title, @JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson)  Category category,  DateTime? dueAt,  DateTime? doneAt,  DateTime? startedAt,  DateTime createdAt,  DateTime updatedAt,  String? calendarEventId,  String? calendarId,  String calendarOrigin,  String? parentId,  TodoType type,  int sortOrder,  String? description,  DateTime? endAt,  bool isAllDay,  String timeAnchor,  String? seriesId,  String? recurrenceRule,  DateTime? recurrenceEndAt,  bool isSeriesMaster)  $default,) {final _that = this;
switch (_that) {
case _Todo():
return $default(_that.id,_that.title,_that.category,_that.dueAt,_that.doneAt,_that.startedAt,_that.createdAt,_that.updatedAt,_that.calendarEventId,_that.calendarId,_that.calendarOrigin,_that.parentId,_that.type,_that.sortOrder,_that.description,_that.endAt,_that.isAllDay,_that.timeAnchor,_that.seriesId,_that.recurrenceRule,_that.recurrenceEndAt,_that.isSeriesMaster);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title, @JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson)  Category category,  DateTime? dueAt,  DateTime? doneAt,  DateTime? startedAt,  DateTime createdAt,  DateTime updatedAt,  String? calendarEventId,  String? calendarId,  String calendarOrigin,  String? parentId,  TodoType type,  int sortOrder,  String? description,  DateTime? endAt,  bool isAllDay,  String timeAnchor,  String? seriesId,  String? recurrenceRule,  DateTime? recurrenceEndAt,  bool isSeriesMaster)?  $default,) {final _that = this;
switch (_that) {
case _Todo() when $default != null:
return $default(_that.id,_that.title,_that.category,_that.dueAt,_that.doneAt,_that.startedAt,_that.createdAt,_that.updatedAt,_that.calendarEventId,_that.calendarId,_that.calendarOrigin,_that.parentId,_that.type,_that.sortOrder,_that.description,_that.endAt,_that.isAllDay,_that.timeAnchor,_that.seriesId,_that.recurrenceRule,_that.recurrenceEndAt,_that.isSeriesMaster);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Todo extends Todo {
  const _Todo({required this.id, required this.title, @JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson) required this.category, this.dueAt, this.doneAt, this.startedAt, required this.createdAt, required this.updatedAt, this.calendarEventId, this.calendarId, this.calendarOrigin = 'app', this.parentId, this.type = TodoType.task, this.sortOrder = 0, this.description, this.endAt, this.isAllDay = false, this.timeAnchor = 'start', this.seriesId, this.recurrenceRule, this.recurrenceEndAt, this.isSeriesMaster = false}): super._();
  factory _Todo.fromJson(Map<String, dynamic> json) => _$TodoFromJson(json);

@override final  String id;
@override final  String title;
@override@JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson) final  Category category;
@override final  DateTime? dueAt;
@override final  DateTime? doneAt;
// 진행중(in-progress) 시작 시각. 값이 있고 doneAt 이 null 이면 "진행중" 상태.
// 완료(doneAt set) 시엔 null 로 비워진다. (note 는 항상 null.)
@override final  DateTime? startedAt;
@override final  DateTime createdAt;
@override final  DateTime updatedAt;
@override final  String? calendarEventId;
// [calendarId] — calendarEventId 가 속한 Google Calendar id. null = 미등록
// 또는 레거시(과거엔 'primary' 하드코딩이었으므로 null 이면 primary 로 간주).
@override final  String? calendarId;
// [calendarOrigin] — 'app'(앱에서 만든 할 일) | 'gcal'(Google Calendar 에서
// 유입된 할 일). **삭제 규칙의 유일한 근거**: 구글 캘린더 쪽 이벤트가 삭제됐을 때
// origin='app' 이면 할 일은 남기고 캘린더 연결만 해제, origin='gcal' 이면 할 일도
// 함께 삭제한다. 반드시 Supabase 로 전파되어 macOS/Android 양쪽이 같은 판단을 한다.
@override@JsonKey() final  String calendarOrigin;
@override final  String? parentId;
@override@JsonKey() final  TodoType type;
@override@JsonKey() final  int sortOrder;
// v1.2 — 상세 메모 (long text). nullable + 누락 시 null 로 안전 fallback.
@override final  String? description;
// ── 날짜·기간 모델 (fast-tasks 4/5/1) — dueAt 은 앵커로 그대로 유지 ──────────
// [endAt] — 기간 모드의 종료 시각. 단일 모드면 null.
@override final  DateTime? endAt;
// [isAllDay] — true 면 시간 미표시 (화면 어디에도 00:00 을 찍지 않음).
@override@JsonKey() final  bool isAllDay;
// [timeAnchor] — 단일·시간 모드에서 dueAt 이 '시작'('start')인지 '마감'('end')인지.
// 하루종일·기간 모드에서는 의미 없음 (기본 'start' 유지).
@override@JsonKey() final  String timeAnchor;
// ── 날짜 반복 (date-repeat) ─────────────────────────────────────────────
// [seriesId] — 소속 반복 시리즈 id. 마스터는 자기 id, 인스턴스는 마스터 id.
//   null = 일반(비반복) Todo.
@override final  String? seriesId;
// [recurrenceRule] — 반복 규칙 직렬화(RecurrenceRule.encode). **마스터에만** 채움.
@override final  String? recurrenceRule;
// [recurrenceEndAt] — 반복 종료일. **마스터에만**. null = 무한.
@override final  DateTime? recurrenceEndAt;
// [isSeriesMaster] — true = 규칙 보유 숨김 템플릿(모든 목록에서 제외, 캘린더 RRULE 소유).
@override@JsonKey() final  bool isSeriesMaster;

/// Create a copy of Todo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TodoCopyWith<_Todo> get copyWith => __$TodoCopyWithImpl<_Todo>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TodoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Todo&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.category, category) || other.category == category)&&(identical(other.dueAt, dueAt) || other.dueAt == dueAt)&&(identical(other.doneAt, doneAt) || other.doneAt == doneAt)&&(identical(other.startedAt, startedAt) || other.startedAt == startedAt)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.calendarEventId, calendarEventId) || other.calendarEventId == calendarEventId)&&(identical(other.calendarId, calendarId) || other.calendarId == calendarId)&&(identical(other.calendarOrigin, calendarOrigin) || other.calendarOrigin == calendarOrigin)&&(identical(other.parentId, parentId) || other.parentId == parentId)&&(identical(other.type, type) || other.type == type)&&(identical(other.sortOrder, sortOrder) || other.sortOrder == sortOrder)&&(identical(other.description, description) || other.description == description)&&(identical(other.endAt, endAt) || other.endAt == endAt)&&(identical(other.isAllDay, isAllDay) || other.isAllDay == isAllDay)&&(identical(other.timeAnchor, timeAnchor) || other.timeAnchor == timeAnchor)&&(identical(other.seriesId, seriesId) || other.seriesId == seriesId)&&(identical(other.recurrenceRule, recurrenceRule) || other.recurrenceRule == recurrenceRule)&&(identical(other.recurrenceEndAt, recurrenceEndAt) || other.recurrenceEndAt == recurrenceEndAt)&&(identical(other.isSeriesMaster, isSeriesMaster) || other.isSeriesMaster == isSeriesMaster));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,title,category,dueAt,doneAt,startedAt,createdAt,updatedAt,calendarEventId,calendarId,calendarOrigin,parentId,type,sortOrder,description,endAt,isAllDay,timeAnchor,seriesId,recurrenceRule,recurrenceEndAt,isSeriesMaster]);

@override
String toString() {
  return 'Todo(id: $id, title: $title, category: $category, dueAt: $dueAt, doneAt: $doneAt, startedAt: $startedAt, createdAt: $createdAt, updatedAt: $updatedAt, calendarEventId: $calendarEventId, calendarId: $calendarId, calendarOrigin: $calendarOrigin, parentId: $parentId, type: $type, sortOrder: $sortOrder, description: $description, endAt: $endAt, isAllDay: $isAllDay, timeAnchor: $timeAnchor, seriesId: $seriesId, recurrenceRule: $recurrenceRule, recurrenceEndAt: $recurrenceEndAt, isSeriesMaster: $isSeriesMaster)';
}


}

/// @nodoc
abstract mixin class _$TodoCopyWith<$Res> implements $TodoCopyWith<$Res> {
  factory _$TodoCopyWith(_Todo value, $Res Function(_Todo) _then) = __$TodoCopyWithImpl;
@override @useResult
$Res call({
 String id, String title,@JsonKey(fromJson: _categoryFromJson, toJson: _categoryToJson) Category category, DateTime? dueAt, DateTime? doneAt, DateTime? startedAt, DateTime createdAt, DateTime updatedAt, String? calendarEventId, String? calendarId, String calendarOrigin, String? parentId, TodoType type, int sortOrder, String? description, DateTime? endAt, bool isAllDay, String timeAnchor, String? seriesId, String? recurrenceRule, DateTime? recurrenceEndAt, bool isSeriesMaster
});


@override $CategoryCopyWith<$Res> get category;

}
/// @nodoc
class __$TodoCopyWithImpl<$Res>
    implements _$TodoCopyWith<$Res> {
  __$TodoCopyWithImpl(this._self, this._then);

  final _Todo _self;
  final $Res Function(_Todo) _then;

/// Create a copy of Todo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? category = null,Object? dueAt = freezed,Object? doneAt = freezed,Object? startedAt = freezed,Object? createdAt = null,Object? updatedAt = null,Object? calendarEventId = freezed,Object? calendarId = freezed,Object? calendarOrigin = null,Object? parentId = freezed,Object? type = null,Object? sortOrder = null,Object? description = freezed,Object? endAt = freezed,Object? isAllDay = null,Object? timeAnchor = null,Object? seriesId = freezed,Object? recurrenceRule = freezed,Object? recurrenceEndAt = freezed,Object? isSeriesMaster = null,}) {
  return _then(_Todo(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,category: null == category ? _self.category : category // ignore: cast_nullable_to_non_nullable
as Category,dueAt: freezed == dueAt ? _self.dueAt : dueAt // ignore: cast_nullable_to_non_nullable
as DateTime?,doneAt: freezed == doneAt ? _self.doneAt : doneAt // ignore: cast_nullable_to_non_nullable
as DateTime?,startedAt: freezed == startedAt ? _self.startedAt : startedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,calendarEventId: freezed == calendarEventId ? _self.calendarEventId : calendarEventId // ignore: cast_nullable_to_non_nullable
as String?,calendarId: freezed == calendarId ? _self.calendarId : calendarId // ignore: cast_nullable_to_non_nullable
as String?,calendarOrigin: null == calendarOrigin ? _self.calendarOrigin : calendarOrigin // ignore: cast_nullable_to_non_nullable
as String,parentId: freezed == parentId ? _self.parentId : parentId // ignore: cast_nullable_to_non_nullable
as String?,type: null == type ? _self.type : type // ignore: cast_nullable_to_non_nullable
as TodoType,sortOrder: null == sortOrder ? _self.sortOrder : sortOrder // ignore: cast_nullable_to_non_nullable
as int,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,endAt: freezed == endAt ? _self.endAt : endAt // ignore: cast_nullable_to_non_nullable
as DateTime?,isAllDay: null == isAllDay ? _self.isAllDay : isAllDay // ignore: cast_nullable_to_non_nullable
as bool,timeAnchor: null == timeAnchor ? _self.timeAnchor : timeAnchor // ignore: cast_nullable_to_non_nullable
as String,seriesId: freezed == seriesId ? _self.seriesId : seriesId // ignore: cast_nullable_to_non_nullable
as String?,recurrenceRule: freezed == recurrenceRule ? _self.recurrenceRule : recurrenceRule // ignore: cast_nullable_to_non_nullable
as String?,recurrenceEndAt: freezed == recurrenceEndAt ? _self.recurrenceEndAt : recurrenceEndAt // ignore: cast_nullable_to_non_nullable
as DateTime?,isSeriesMaster: null == isSeriesMaster ? _self.isSeriesMaster : isSeriesMaster // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of Todo
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$CategoryCopyWith<$Res> get category {
  
  return $CategoryCopyWith<$Res>(_self.category, (value) {
    return _then(_self.copyWith(category: value));
  });
}
}

// dart format on

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calendar_ops_dao.dart';

// ignore_for_file: type=lint
mixin _$CalendarOpsDaoMixin on DatabaseAccessor<AppDatabase> {
  $CalendarOpsTable get calendarOps => attachedDatabase.calendarOps;
  CalendarOpsDaoManager get managers => CalendarOpsDaoManager(this);
}

class CalendarOpsDaoManager {
  final _$CalendarOpsDaoMixin _db;
  CalendarOpsDaoManager(this._db);
  $$CalendarOpsTableTableManager get calendarOps =>
      $$CalendarOpsTableTableManager(_db.attachedDatabase, _db.calendarOps);
}

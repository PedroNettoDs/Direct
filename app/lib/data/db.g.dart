// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// ignore_for_file: type=lint
class $LocalProfilesTable extends LocalProfiles
    with TableInfo<$LocalProfilesTable, LocalProfile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, displayName, status];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalProfile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalProfile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalProfile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
    );
  }

  @override
  $LocalProfilesTable createAlias(String alias) {
    return $LocalProfilesTable(attachedDatabase, alias);
  }
}

class LocalProfile extends DataClass implements Insertable<LocalProfile> {
  final int id;
  final String displayName;
  final String status;
  const LocalProfile({
    required this.id,
    required this.displayName,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['display_name'] = Variable<String>(displayName);
    map['status'] = Variable<String>(status);
    return map;
  }

  LocalProfilesCompanion toCompanion(bool nullToAbsent) {
    return LocalProfilesCompanion(
      id: Value(id),
      displayName: Value(displayName),
      status: Value(status),
    );
  }

  factory LocalProfile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalProfile(
      id: serializer.fromJson<int>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      status: serializer.fromJson<String>(json['status']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'displayName': serializer.toJson<String>(displayName),
      'status': serializer.toJson<String>(status),
    };
  }

  LocalProfile copyWith({int? id, String? displayName, String? status}) =>
      LocalProfile(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        status: status ?? this.status,
      );
  LocalProfile copyWithCompanion(LocalProfilesCompanion data) {
    return LocalProfile(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalProfile(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, displayName, status);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalProfile &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.status == this.status);
}

class LocalProfilesCompanion extends UpdateCompanion<LocalProfile> {
  final Value<int> id;
  final Value<String> displayName;
  final Value<String> status;
  const LocalProfilesCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.status = const Value.absent(),
  });
  LocalProfilesCompanion.insert({
    this.id = const Value.absent(),
    required String displayName,
    required String status,
  }) : displayName = Value(displayName),
       status = Value(status);
  static Insertable<LocalProfile> custom({
    Expression<int>? id,
    Expression<String>? displayName,
    Expression<String>? status,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (status != null) 'status': status,
    });
  }

  LocalProfilesCompanion copyWith({
    Value<int>? id,
    Value<String>? displayName,
    Value<String>? status,
  }) {
    return LocalProfilesCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      status: status ?? this.status,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalProfilesCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }
}

class $DirUsersTable extends DirUsers with TableInfo<$DirUsersTable, DirUser> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DirUsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _adminLabelMeta = const VerificationMeta(
    'adminLabel',
  );
  @override
  late final GeneratedColumn<String> adminLabel = GeneratedColumn<String>(
    'admin_label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    adminLabel,
    displayName,
    status,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'dir_users';
  @override
  VerificationContext validateIntegrity(
    Insertable<DirUser> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('admin_label')) {
      context.handle(
        _adminLabelMeta,
        adminLabel.isAcceptableOrUnknown(data['admin_label']!, _adminLabelMeta),
      );
    } else if (isInserting) {
      context.missing(_adminLabelMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  DirUser map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DirUser(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      adminLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}admin_label'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
    );
  }

  @override
  $DirUsersTable createAlias(String alias) {
    return $DirUsersTable(attachedDatabase, alias);
  }
}

class DirUser extends DataClass implements Insertable<DirUser> {
  final String userId;
  final String adminLabel;
  final String displayName;
  final String status;
  const DirUser({
    required this.userId,
    required this.adminLabel,
    required this.displayName,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['admin_label'] = Variable<String>(adminLabel);
    map['display_name'] = Variable<String>(displayName);
    map['status'] = Variable<String>(status);
    return map;
  }

  DirUsersCompanion toCompanion(bool nullToAbsent) {
    return DirUsersCompanion(
      userId: Value(userId),
      adminLabel: Value(adminLabel),
      displayName: Value(displayName),
      status: Value(status),
    );
  }

  factory DirUser.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DirUser(
      userId: serializer.fromJson<String>(json['userId']),
      adminLabel: serializer.fromJson<String>(json['adminLabel']),
      displayName: serializer.fromJson<String>(json['displayName']),
      status: serializer.fromJson<String>(json['status']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'adminLabel': serializer.toJson<String>(adminLabel),
      'displayName': serializer.toJson<String>(displayName),
      'status': serializer.toJson<String>(status),
    };
  }

  DirUser copyWith({
    String? userId,
    String? adminLabel,
    String? displayName,
    String? status,
  }) => DirUser(
    userId: userId ?? this.userId,
    adminLabel: adminLabel ?? this.adminLabel,
    displayName: displayName ?? this.displayName,
    status: status ?? this.status,
  );
  DirUser copyWithCompanion(DirUsersCompanion data) {
    return DirUser(
      userId: data.userId.present ? data.userId.value : this.userId,
      adminLabel: data.adminLabel.present
          ? data.adminLabel.value
          : this.adminLabel,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DirUser(')
          ..write('userId: $userId, ')
          ..write('adminLabel: $adminLabel, ')
          ..write('displayName: $displayName, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(userId, adminLabel, displayName, status);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DirUser &&
          other.userId == this.userId &&
          other.adminLabel == this.adminLabel &&
          other.displayName == this.displayName &&
          other.status == this.status);
}

class DirUsersCompanion extends UpdateCompanion<DirUser> {
  final Value<String> userId;
  final Value<String> adminLabel;
  final Value<String> displayName;
  final Value<String> status;
  final Value<int> rowid;
  const DirUsersCompanion({
    this.userId = const Value.absent(),
    this.adminLabel = const Value.absent(),
    this.displayName = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DirUsersCompanion.insert({
    required String userId,
    required String adminLabel,
    required String displayName,
    required String status,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       adminLabel = Value(adminLabel),
       displayName = Value(displayName),
       status = Value(status);
  static Insertable<DirUser> custom({
    Expression<String>? userId,
    Expression<String>? adminLabel,
    Expression<String>? displayName,
    Expression<String>? status,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (adminLabel != null) 'admin_label': adminLabel,
      if (displayName != null) 'display_name': displayName,
      if (status != null) 'status': status,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DirUsersCompanion copyWith({
    Value<String>? userId,
    Value<String>? adminLabel,
    Value<String>? displayName,
    Value<String>? status,
    Value<int>? rowid,
  }) {
    return DirUsersCompanion(
      userId: userId ?? this.userId,
      adminLabel: adminLabel ?? this.adminLabel,
      displayName: displayName ?? this.displayName,
      status: status ?? this.status,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (adminLabel.present) {
      map['admin_label'] = Variable<String>(adminLabel.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DirUsersCompanion(')
          ..write('userId: $userId, ')
          ..write('adminLabel: $adminLabel, ')
          ..write('displayName: $displayName, ')
          ..write('status: $status, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KnownDevicesTable extends KnownDevices
    with TableInfo<$KnownDevicesTable, KnownDevice> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnownDevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _certJsonMeta = const VerificationMeta(
    'certJson',
  );
  @override
  late final GeneratedColumn<String> certJson = GeneratedColumn<String>(
    'cert_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _activeMeta = const VerificationMeta('active');
  @override
  late final GeneratedColumn<bool> active = GeneratedColumn<bool>(
    'active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("active" IN (0, 1))',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [deviceId, userId, certJson, active];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'known_devices';
  @override
  VerificationContext validateIntegrity(
    Insertable<KnownDevice> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('cert_json')) {
      context.handle(
        _certJsonMeta,
        certJson.isAcceptableOrUnknown(data['cert_json']!, _certJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_certJsonMeta);
    }
    if (data.containsKey('active')) {
      context.handle(
        _activeMeta,
        active.isAcceptableOrUnknown(data['active']!, _activeMeta),
      );
    } else if (isInserting) {
      context.missing(_activeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {deviceId};
  @override
  KnownDevice map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KnownDevice(
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      certJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cert_json'],
      )!,
      active: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}active'],
      )!,
    );
  }

  @override
  $KnownDevicesTable createAlias(String alias) {
    return $KnownDevicesTable(attachedDatabase, alias);
  }
}

class KnownDevice extends DataClass implements Insertable<KnownDevice> {
  final String deviceId;
  final String userId;
  final String certJson;
  final bool active;
  const KnownDevice({
    required this.deviceId,
    required this.userId,
    required this.certJson,
    required this.active,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['device_id'] = Variable<String>(deviceId);
    map['user_id'] = Variable<String>(userId);
    map['cert_json'] = Variable<String>(certJson);
    map['active'] = Variable<bool>(active);
    return map;
  }

  KnownDevicesCompanion toCompanion(bool nullToAbsent) {
    return KnownDevicesCompanion(
      deviceId: Value(deviceId),
      userId: Value(userId),
      certJson: Value(certJson),
      active: Value(active),
    );
  }

  factory KnownDevice.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KnownDevice(
      deviceId: serializer.fromJson<String>(json['deviceId']),
      userId: serializer.fromJson<String>(json['userId']),
      certJson: serializer.fromJson<String>(json['certJson']),
      active: serializer.fromJson<bool>(json['active']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'deviceId': serializer.toJson<String>(deviceId),
      'userId': serializer.toJson<String>(userId),
      'certJson': serializer.toJson<String>(certJson),
      'active': serializer.toJson<bool>(active),
    };
  }

  KnownDevice copyWith({
    String? deviceId,
    String? userId,
    String? certJson,
    bool? active,
  }) => KnownDevice(
    deviceId: deviceId ?? this.deviceId,
    userId: userId ?? this.userId,
    certJson: certJson ?? this.certJson,
    active: active ?? this.active,
  );
  KnownDevice copyWithCompanion(KnownDevicesCompanion data) {
    return KnownDevice(
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      userId: data.userId.present ? data.userId.value : this.userId,
      certJson: data.certJson.present ? data.certJson.value : this.certJson,
      active: data.active.present ? data.active.value : this.active,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KnownDevice(')
          ..write('deviceId: $deviceId, ')
          ..write('userId: $userId, ')
          ..write('certJson: $certJson, ')
          ..write('active: $active')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(deviceId, userId, certJson, active);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnownDevice &&
          other.deviceId == this.deviceId &&
          other.userId == this.userId &&
          other.certJson == this.certJson &&
          other.active == this.active);
}

class KnownDevicesCompanion extends UpdateCompanion<KnownDevice> {
  final Value<String> deviceId;
  final Value<String> userId;
  final Value<String> certJson;
  final Value<bool> active;
  final Value<int> rowid;
  const KnownDevicesCompanion({
    this.deviceId = const Value.absent(),
    this.userId = const Value.absent(),
    this.certJson = const Value.absent(),
    this.active = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KnownDevicesCompanion.insert({
    required String deviceId,
    required String userId,
    required String certJson,
    required bool active,
    this.rowid = const Value.absent(),
  }) : deviceId = Value(deviceId),
       userId = Value(userId),
       certJson = Value(certJson),
       active = Value(active);
  static Insertable<KnownDevice> custom({
    Expression<String>? deviceId,
    Expression<String>? userId,
    Expression<String>? certJson,
    Expression<bool>? active,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (deviceId != null) 'device_id': deviceId,
      if (userId != null) 'user_id': userId,
      if (certJson != null) 'cert_json': certJson,
      if (active != null) 'active': active,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KnownDevicesCompanion copyWith({
    Value<String>? deviceId,
    Value<String>? userId,
    Value<String>? certJson,
    Value<bool>? active,
    Value<int>? rowid,
  }) {
    return KnownDevicesCompanion(
      deviceId: deviceId ?? this.deviceId,
      userId: userId ?? this.userId,
      certJson: certJson ?? this.certJson,
      active: active ?? this.active,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (certJson.present) {
      map['cert_json'] = Variable<String>(certJson.value);
    }
    if (active.present) {
      map['active'] = Variable<bool>(active.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnownDevicesCompanion(')
          ..write('deviceId: $deviceId, ')
          ..write('userId: $userId, ')
          ..write('certJson: $certJson, ')
          ..write('active: $active, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SeenKeysTable extends SeenKeys with TableInfo<$SeenKeysTable, SeenKey> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SeenKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signPubMeta = const VerificationMeta(
    'signPub',
  );
  @override
  late final GeneratedColumn<String> signPub = GeneratedColumn<String>(
    'sign_pub',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _presentMeta = const VerificationMeta(
    'present',
  );
  @override
  late final GeneratedColumn<bool> present = GeneratedColumn<bool>(
    'present',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("present" IN (0, 1))',
    ),
  );
  static const VerificationMeta _noticedAtMeta = const VerificationMeta(
    'noticedAt',
  );
  @override
  late final GeneratedColumn<int> noticedAt = GeneratedColumn<int>(
    'noticed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [userId, signPub, present, noticedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'seen_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SeenKey> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('sign_pub')) {
      context.handle(
        _signPubMeta,
        signPub.isAcceptableOrUnknown(data['sign_pub']!, _signPubMeta),
      );
    } else if (isInserting) {
      context.missing(_signPubMeta);
    }
    if (data.containsKey('present')) {
      context.handle(
        _presentMeta,
        present.isAcceptableOrUnknown(data['present']!, _presentMeta),
      );
    } else if (isInserting) {
      context.missing(_presentMeta);
    }
    if (data.containsKey('noticed_at')) {
      context.handle(
        _noticedAtMeta,
        noticedAt.isAcceptableOrUnknown(data['noticed_at']!, _noticedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, signPub};
  @override
  SeenKey map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SeenKey(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      signPub: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sign_pub'],
      )!,
      present: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}present'],
      )!,
      noticedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}noticed_at'],
      ),
    );
  }

  @override
  $SeenKeysTable createAlias(String alias) {
    return $SeenKeysTable(attachedDatabase, alias);
  }
}

class SeenKey extends DataClass implements Insertable<SeenKey> {
  final String userId;
  final String signPub;
  final bool present;

  /// Quando o app avisou que este era um aparelho novo (§7.3); os grupos
  /// montam a linha a partir daqui.
  final int? noticedAt;
  const SeenKey({
    required this.userId,
    required this.signPub,
    required this.present,
    this.noticedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['sign_pub'] = Variable<String>(signPub);
    map['present'] = Variable<bool>(present);
    if (!nullToAbsent || noticedAt != null) {
      map['noticed_at'] = Variable<int>(noticedAt);
    }
    return map;
  }

  SeenKeysCompanion toCompanion(bool nullToAbsent) {
    return SeenKeysCompanion(
      userId: Value(userId),
      signPub: Value(signPub),
      present: Value(present),
      noticedAt: noticedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(noticedAt),
    );
  }

  factory SeenKey.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SeenKey(
      userId: serializer.fromJson<String>(json['userId']),
      signPub: serializer.fromJson<String>(json['signPub']),
      present: serializer.fromJson<bool>(json['present']),
      noticedAt: serializer.fromJson<int?>(json['noticedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'signPub': serializer.toJson<String>(signPub),
      'present': serializer.toJson<bool>(present),
      'noticedAt': serializer.toJson<int?>(noticedAt),
    };
  }

  SeenKey copyWith({
    String? userId,
    String? signPub,
    bool? present,
    Value<int?> noticedAt = const Value.absent(),
  }) => SeenKey(
    userId: userId ?? this.userId,
    signPub: signPub ?? this.signPub,
    present: present ?? this.present,
    noticedAt: noticedAt.present ? noticedAt.value : this.noticedAt,
  );
  SeenKey copyWithCompanion(SeenKeysCompanion data) {
    return SeenKey(
      userId: data.userId.present ? data.userId.value : this.userId,
      signPub: data.signPub.present ? data.signPub.value : this.signPub,
      present: data.present.present ? data.present.value : this.present,
      noticedAt: data.noticedAt.present ? data.noticedAt.value : this.noticedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SeenKey(')
          ..write('userId: $userId, ')
          ..write('signPub: $signPub, ')
          ..write('present: $present, ')
          ..write('noticedAt: $noticedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(userId, signPub, present, noticedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SeenKey &&
          other.userId == this.userId &&
          other.signPub == this.signPub &&
          other.present == this.present &&
          other.noticedAt == this.noticedAt);
}

class SeenKeysCompanion extends UpdateCompanion<SeenKey> {
  final Value<String> userId;
  final Value<String> signPub;
  final Value<bool> present;
  final Value<int?> noticedAt;
  final Value<int> rowid;
  const SeenKeysCompanion({
    this.userId = const Value.absent(),
    this.signPub = const Value.absent(),
    this.present = const Value.absent(),
    this.noticedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SeenKeysCompanion.insert({
    required String userId,
    required String signPub,
    required bool present,
    this.noticedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       signPub = Value(signPub),
       present = Value(present);
  static Insertable<SeenKey> custom({
    Expression<String>? userId,
    Expression<String>? signPub,
    Expression<bool>? present,
    Expression<int>? noticedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (signPub != null) 'sign_pub': signPub,
      if (present != null) 'present': present,
      if (noticedAt != null) 'noticed_at': noticedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SeenKeysCompanion copyWith({
    Value<String>? userId,
    Value<String>? signPub,
    Value<bool>? present,
    Value<int?>? noticedAt,
    Value<int>? rowid,
  }) {
    return SeenKeysCompanion(
      userId: userId ?? this.userId,
      signPub: signPub ?? this.signPub,
      present: present ?? this.present,
      noticedAt: noticedAt ?? this.noticedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (signPub.present) {
      map['sign_pub'] = Variable<String>(signPub.value);
    }
    if (present.present) {
      map['present'] = Variable<bool>(present.value);
    }
    if (noticedAt.present) {
      map['noticed_at'] = Variable<int>(noticedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SeenKeysCompanion(')
          ..write('userId: $userId, ')
          ..write('signPub: $signPub, ')
          ..write('present: $present, ')
          ..write('noticedAt: $noticedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, Conversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerUserIdMeta = const VerificationMeta(
    'peerUserId',
  );
  @override
  late final GeneratedColumn<String> peerUserId = GeneratedColumn<String>(
    'peer_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _membersJsonMeta = const VerificationMeta(
    'membersJson',
  );
  @override
  late final GeneratedColumn<String> membersJson = GeneratedColumn<String>(
    'members_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _latestEpochMeta = const VerificationMeta(
    'latestEpoch',
  );
  @override
  late final GeneratedColumn<int> latestEpoch = GeneratedColumn<int>(
    'latest_epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    peerUserId,
    membersJson,
    latestEpoch,
    syncedSeq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<Conversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('peer_user_id')) {
      context.handle(
        _peerUserIdMeta,
        peerUserId.isAcceptableOrUnknown(
          data['peer_user_id']!,
          _peerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_peerUserIdMeta);
    }
    if (data.containsKey('members_json')) {
      context.handle(
        _membersJsonMeta,
        membersJson.isAcceptableOrUnknown(
          data['members_json']!,
          _membersJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_membersJsonMeta);
    }
    if (data.containsKey('latest_epoch')) {
      context.handle(
        _latestEpochMeta,
        latestEpoch.isAcceptableOrUnknown(
          data['latest_epoch']!,
          _latestEpochMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_latestEpochMeta);
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_syncedSeqMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  Conversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Conversation(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      peerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_user_id'],
      )!,
      membersJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}members_json'],
      )!,
      latestEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}latest_epoch'],
      )!,
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      )!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class Conversation extends DataClass implements Insertable<Conversation> {
  final String conversationId;
  final String peerUserId;
  final String membersJson;
  final int latestEpoch;

  /// Maior `seq` já processado (inclui descartadas e à espera de chave).
  final int syncedSeq;
  const Conversation({
    required this.conversationId,
    required this.peerUserId,
    required this.membersJson,
    required this.latestEpoch,
    required this.syncedSeq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['peer_user_id'] = Variable<String>(peerUserId);
    map['members_json'] = Variable<String>(membersJson);
    map['latest_epoch'] = Variable<int>(latestEpoch);
    map['synced_seq'] = Variable<int>(syncedSeq);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      conversationId: Value(conversationId),
      peerUserId: Value(peerUserId),
      membersJson: Value(membersJson),
      latestEpoch: Value(latestEpoch),
      syncedSeq: Value(syncedSeq),
    );
  }

  factory Conversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Conversation(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      peerUserId: serializer.fromJson<String>(json['peerUserId']),
      membersJson: serializer.fromJson<String>(json['membersJson']),
      latestEpoch: serializer.fromJson<int>(json['latestEpoch']),
      syncedSeq: serializer.fromJson<int>(json['syncedSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'peerUserId': serializer.toJson<String>(peerUserId),
      'membersJson': serializer.toJson<String>(membersJson),
      'latestEpoch': serializer.toJson<int>(latestEpoch),
      'syncedSeq': serializer.toJson<int>(syncedSeq),
    };
  }

  Conversation copyWith({
    String? conversationId,
    String? peerUserId,
    String? membersJson,
    int? latestEpoch,
    int? syncedSeq,
  }) => Conversation(
    conversationId: conversationId ?? this.conversationId,
    peerUserId: peerUserId ?? this.peerUserId,
    membersJson: membersJson ?? this.membersJson,
    latestEpoch: latestEpoch ?? this.latestEpoch,
    syncedSeq: syncedSeq ?? this.syncedSeq,
  );
  Conversation copyWithCompanion(ConversationsCompanion data) {
    return Conversation(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      peerUserId: data.peerUserId.present
          ? data.peerUserId.value
          : this.peerUserId,
      membersJson: data.membersJson.present
          ? data.membersJson.value
          : this.membersJson,
      latestEpoch: data.latestEpoch.present
          ? data.latestEpoch.value
          : this.latestEpoch,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Conversation(')
          ..write('conversationId: $conversationId, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('membersJson: $membersJson, ')
          ..write('latestEpoch: $latestEpoch, ')
          ..write('syncedSeq: $syncedSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    peerUserId,
    membersJson,
    latestEpoch,
    syncedSeq,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Conversation &&
          other.conversationId == this.conversationId &&
          other.peerUserId == this.peerUserId &&
          other.membersJson == this.membersJson &&
          other.latestEpoch == this.latestEpoch &&
          other.syncedSeq == this.syncedSeq);
}

class ConversationsCompanion extends UpdateCompanion<Conversation> {
  final Value<String> conversationId;
  final Value<String> peerUserId;
  final Value<String> membersJson;
  final Value<int> latestEpoch;
  final Value<int> syncedSeq;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.conversationId = const Value.absent(),
    this.peerUserId = const Value.absent(),
    this.membersJson = const Value.absent(),
    this.latestEpoch = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String conversationId,
    required String peerUserId,
    required String membersJson,
    required int latestEpoch,
    required int syncedSeq,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       peerUserId = Value(peerUserId),
       membersJson = Value(membersJson),
       latestEpoch = Value(latestEpoch),
       syncedSeq = Value(syncedSeq);
  static Insertable<Conversation> custom({
    Expression<String>? conversationId,
    Expression<String>? peerUserId,
    Expression<String>? membersJson,
    Expression<int>? latestEpoch,
    Expression<int>? syncedSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (peerUserId != null) 'peer_user_id': peerUserId,
      if (membersJson != null) 'members_json': membersJson,
      if (latestEpoch != null) 'latest_epoch': latestEpoch,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? peerUserId,
    Value<String>? membersJson,
    Value<int>? latestEpoch,
    Value<int>? syncedSeq,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      conversationId: conversationId ?? this.conversationId,
      peerUserId: peerUserId ?? this.peerUserId,
      membersJson: membersJson ?? this.membersJson,
      latestEpoch: latestEpoch ?? this.latestEpoch,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (peerUserId.present) {
      map['peer_user_id'] = Variable<String>(peerUserId.value);
    }
    if (membersJson.present) {
      map['members_json'] = Variable<String>(membersJson.value);
    }
    if (latestEpoch.present) {
      map['latest_epoch'] = Variable<int>(latestEpoch.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('membersJson: $membersJson, ')
          ..write('latestEpoch: $latestEpoch, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $EpochKeysTable extends EpochKeys
    with TableInfo<$EpochKeysTable, EpochKey> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EpochKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<Uint8List> key = GeneratedColumn<Uint8List>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recipientsJsonMeta = const VerificationMeta(
    'recipientsJson',
  );
  @override
  late final GeneratedColumn<String> recipientsJson = GeneratedColumn<String>(
    'recipients_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    epoch,
    key,
    recipientsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'epoch_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<EpochKey> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('recipients_json')) {
      context.handle(
        _recipientsJsonMeta,
        recipientsJson.isAcceptableOrUnknown(
          data['recipients_json']!,
          _recipientsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_recipientsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, epoch};
  @override
  EpochKey map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EpochKey(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}key'],
      )!,
      recipientsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recipients_json'],
      )!,
    );
  }

  @override
  $EpochKeysTable createAlias(String alias) {
    return $EpochKeysTable(attachedDatabase, alias);
  }
}

class EpochKey extends DataClass implements Insertable<EpochKey> {
  final String conversationId;
  final int epoch;
  final Uint8List key;
  final String recipientsJson;
  const EpochKey({
    required this.conversationId,
    required this.epoch,
    required this.key,
    required this.recipientsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['epoch'] = Variable<int>(epoch);
    map['key'] = Variable<Uint8List>(key);
    map['recipients_json'] = Variable<String>(recipientsJson);
    return map;
  }

  EpochKeysCompanion toCompanion(bool nullToAbsent) {
    return EpochKeysCompanion(
      conversationId: Value(conversationId),
      epoch: Value(epoch),
      key: Value(key),
      recipientsJson: Value(recipientsJson),
    );
  }

  factory EpochKey.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EpochKey(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      epoch: serializer.fromJson<int>(json['epoch']),
      key: serializer.fromJson<Uint8List>(json['key']),
      recipientsJson: serializer.fromJson<String>(json['recipientsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'epoch': serializer.toJson<int>(epoch),
      'key': serializer.toJson<Uint8List>(key),
      'recipientsJson': serializer.toJson<String>(recipientsJson),
    };
  }

  EpochKey copyWith({
    String? conversationId,
    int? epoch,
    Uint8List? key,
    String? recipientsJson,
  }) => EpochKey(
    conversationId: conversationId ?? this.conversationId,
    epoch: epoch ?? this.epoch,
    key: key ?? this.key,
    recipientsJson: recipientsJson ?? this.recipientsJson,
  );
  EpochKey copyWithCompanion(EpochKeysCompanion data) {
    return EpochKey(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      key: data.key.present ? data.key.value : this.key,
      recipientsJson: data.recipientsJson.present
          ? data.recipientsJson.value
          : this.recipientsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EpochKey(')
          ..write('conversationId: $conversationId, ')
          ..write('epoch: $epoch, ')
          ..write('key: $key, ')
          ..write('recipientsJson: $recipientsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conversationId,
    epoch,
    $driftBlobEquality.hash(key),
    recipientsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EpochKey &&
          other.conversationId == this.conversationId &&
          other.epoch == this.epoch &&
          $driftBlobEquality.equals(other.key, this.key) &&
          other.recipientsJson == this.recipientsJson);
}

class EpochKeysCompanion extends UpdateCompanion<EpochKey> {
  final Value<String> conversationId;
  final Value<int> epoch;
  final Value<Uint8List> key;
  final Value<String> recipientsJson;
  final Value<int> rowid;
  const EpochKeysCompanion({
    this.conversationId = const Value.absent(),
    this.epoch = const Value.absent(),
    this.key = const Value.absent(),
    this.recipientsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EpochKeysCompanion.insert({
    required String conversationId,
    required int epoch,
    required Uint8List key,
    required String recipientsJson,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       epoch = Value(epoch),
       key = Value(key),
       recipientsJson = Value(recipientsJson);
  static Insertable<EpochKey> custom({
    Expression<String>? conversationId,
    Expression<int>? epoch,
    Expression<Uint8List>? key,
    Expression<String>? recipientsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (epoch != null) 'epoch': epoch,
      if (key != null) 'key': key,
      if (recipientsJson != null) 'recipients_json': recipientsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EpochKeysCompanion copyWith({
    Value<String>? conversationId,
    Value<int>? epoch,
    Value<Uint8List>? key,
    Value<String>? recipientsJson,
    Value<int>? rowid,
  }) {
    return EpochKeysCompanion(
      conversationId: conversationId ?? this.conversationId,
      epoch: epoch ?? this.epoch,
      key: key ?? this.key,
      recipientsJson: recipientsJson ?? this.recipientsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (key.present) {
      map['key'] = Variable<Uint8List>(key.value);
    }
    if (recipientsJson.present) {
      map['recipients_json'] = Variable<String>(recipientsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EpochKeysCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('epoch: $epoch, ')
          ..write('key: $key, ')
          ..write('recipientsJson: $recipientsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChatMessagesTable extends ChatMessages
    with TableInfo<$ChatMessagesTable, ChatMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderDeviceIdMeta = const VerificationMeta(
    'senderDeviceId',
  );
  @override
  late final GeneratedColumn<String> senderDeviceId = GeneratedColumn<String>(
    'sender_device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sentAtMeta = const VerificationMeta('sentAt');
  @override
  late final GeneratedColumn<int> sentAt = GeneratedColumn<int>(
    'sent_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<int> kind = GeneratedColumn<int>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<int> state = GeneratedColumn<int>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mineMeta = const VerificationMeta('mine');
  @override
  late final GeneratedColumn<bool> mine = GeneratedColumn<bool>(
    'mine',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("mine" IN (0, 1))',
    ),
  );
  static const VerificationMeta _nonceMeta = const VerificationMeta('nonce');
  @override
  late final GeneratedColumn<Uint8List> nonce = GeneratedColumn<Uint8List>(
    'nonce',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ciphertextMeta = const VerificationMeta(
    'ciphertext',
  );
  @override
  late final GeneratedColumn<Uint8List> ciphertext = GeneratedColumn<Uint8List>(
    'ciphertext',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _signatureMeta = const VerificationMeta(
    'signature',
  );
  @override
  late final GeneratedColumn<Uint8List> signature = GeneratedColumn<Uint8List>(
    'signature',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    conversationId,
    messageId,
    seq,
    epoch,
    senderDeviceId,
    sentAt,
    body,
    kind,
    state,
    mine,
    nonce,
    ciphertext,
    signature,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChatMessage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('sender_device_id')) {
      context.handle(
        _senderDeviceIdMeta,
        senderDeviceId.isAcceptableOrUnknown(
          data['sender_device_id']!,
          _senderDeviceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_senderDeviceIdMeta);
    }
    if (data.containsKey('sent_at')) {
      context.handle(
        _sentAtMeta,
        sentAt.isAcceptableOrUnknown(data['sent_at']!, _sentAtMeta),
      );
    } else if (isInserting) {
      context.missing(_sentAtMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('mine')) {
      context.handle(
        _mineMeta,
        mine.isAcceptableOrUnknown(data['mine']!, _mineMeta),
      );
    } else if (isInserting) {
      context.missing(_mineMeta);
    }
    if (data.containsKey('nonce')) {
      context.handle(
        _nonceMeta,
        nonce.isAcceptableOrUnknown(data['nonce']!, _nonceMeta),
      );
    }
    if (data.containsKey('ciphertext')) {
      context.handle(
        _ciphertextMeta,
        ciphertext.isAcceptableOrUnknown(data['ciphertext']!, _ciphertextMeta),
      );
    }
    if (data.containsKey('signature')) {
      context.handle(
        _signatureMeta,
        signature.isAcceptableOrUnknown(data['signature']!, _signatureMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {conversationId, messageId},
  ];
  @override
  ChatMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMessage(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      ),
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      senderDeviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_device_id'],
      )!,
      sentAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sent_at'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      ),
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}kind'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}state'],
      )!,
      mine: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}mine'],
      )!,
      nonce: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}nonce'],
      ),
      ciphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}ciphertext'],
      ),
      signature: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}signature'],
      ),
    );
  }

  @override
  $ChatMessagesTable createAlias(String alias) {
    return $ChatMessagesTable(attachedDatabase, alias);
  }
}

class ChatMessage extends DataClass implements Insertable<ChatMessage> {
  final int id;
  final String conversationId;
  final String messageId;
  final int? seq;
  final int epoch;
  final String senderDeviceId;
  final int sentAt;
  final String? body;

  /// `kindText` ou `kindImage`; em imagem, `body` guarda o JSON de §18.1 (com a chave da imagem).
  final int kind;
  final int state;
  final bool mine;
  final Uint8List? nonce;
  final Uint8List? ciphertext;
  final Uint8List? signature;
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.messageId,
    this.seq,
    required this.epoch,
    required this.senderDeviceId,
    required this.sentAt,
    this.body,
    required this.kind,
    required this.state,
    required this.mine,
    this.nonce,
    this.ciphertext,
    this.signature,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['message_id'] = Variable<String>(messageId);
    if (!nullToAbsent || seq != null) {
      map['seq'] = Variable<int>(seq);
    }
    map['epoch'] = Variable<int>(epoch);
    map['sender_device_id'] = Variable<String>(senderDeviceId);
    map['sent_at'] = Variable<int>(sentAt);
    if (!nullToAbsent || body != null) {
      map['body'] = Variable<String>(body);
    }
    map['kind'] = Variable<int>(kind);
    map['state'] = Variable<int>(state);
    map['mine'] = Variable<bool>(mine);
    if (!nullToAbsent || nonce != null) {
      map['nonce'] = Variable<Uint8List>(nonce);
    }
    if (!nullToAbsent || ciphertext != null) {
      map['ciphertext'] = Variable<Uint8List>(ciphertext);
    }
    if (!nullToAbsent || signature != null) {
      map['signature'] = Variable<Uint8List>(signature);
    }
    return map;
  }

  ChatMessagesCompanion toCompanion(bool nullToAbsent) {
    return ChatMessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      messageId: Value(messageId),
      seq: seq == null && nullToAbsent ? const Value.absent() : Value(seq),
      epoch: Value(epoch),
      senderDeviceId: Value(senderDeviceId),
      sentAt: Value(sentAt),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      kind: Value(kind),
      state: Value(state),
      mine: Value(mine),
      nonce: nonce == null && nullToAbsent
          ? const Value.absent()
          : Value(nonce),
      ciphertext: ciphertext == null && nullToAbsent
          ? const Value.absent()
          : Value(ciphertext),
      signature: signature == null && nullToAbsent
          ? const Value.absent()
          : Value(signature),
    );
  }

  factory ChatMessage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMessage(
      id: serializer.fromJson<int>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      seq: serializer.fromJson<int?>(json['seq']),
      epoch: serializer.fromJson<int>(json['epoch']),
      senderDeviceId: serializer.fromJson<String>(json['senderDeviceId']),
      sentAt: serializer.fromJson<int>(json['sentAt']),
      body: serializer.fromJson<String?>(json['body']),
      kind: serializer.fromJson<int>(json['kind']),
      state: serializer.fromJson<int>(json['state']),
      mine: serializer.fromJson<bool>(json['mine']),
      nonce: serializer.fromJson<Uint8List?>(json['nonce']),
      ciphertext: serializer.fromJson<Uint8List?>(json['ciphertext']),
      signature: serializer.fromJson<Uint8List?>(json['signature']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'messageId': serializer.toJson<String>(messageId),
      'seq': serializer.toJson<int?>(seq),
      'epoch': serializer.toJson<int>(epoch),
      'senderDeviceId': serializer.toJson<String>(senderDeviceId),
      'sentAt': serializer.toJson<int>(sentAt),
      'body': serializer.toJson<String?>(body),
      'kind': serializer.toJson<int>(kind),
      'state': serializer.toJson<int>(state),
      'mine': serializer.toJson<bool>(mine),
      'nonce': serializer.toJson<Uint8List?>(nonce),
      'ciphertext': serializer.toJson<Uint8List?>(ciphertext),
      'signature': serializer.toJson<Uint8List?>(signature),
    };
  }

  ChatMessage copyWith({
    int? id,
    String? conversationId,
    String? messageId,
    Value<int?> seq = const Value.absent(),
    int? epoch,
    String? senderDeviceId,
    int? sentAt,
    Value<String?> body = const Value.absent(),
    int? kind,
    int? state,
    bool? mine,
    Value<Uint8List?> nonce = const Value.absent(),
    Value<Uint8List?> ciphertext = const Value.absent(),
    Value<Uint8List?> signature = const Value.absent(),
  }) => ChatMessage(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    seq: seq.present ? seq.value : this.seq,
    epoch: epoch ?? this.epoch,
    senderDeviceId: senderDeviceId ?? this.senderDeviceId,
    sentAt: sentAt ?? this.sentAt,
    body: body.present ? body.value : this.body,
    kind: kind ?? this.kind,
    state: state ?? this.state,
    mine: mine ?? this.mine,
    nonce: nonce.present ? nonce.value : this.nonce,
    ciphertext: ciphertext.present ? ciphertext.value : this.ciphertext,
    signature: signature.present ? signature.value : this.signature,
  );
  ChatMessage copyWithCompanion(ChatMessagesCompanion data) {
    return ChatMessage(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      seq: data.seq.present ? data.seq.value : this.seq,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      senderDeviceId: data.senderDeviceId.present
          ? data.senderDeviceId.value
          : this.senderDeviceId,
      sentAt: data.sentAt.present ? data.sentAt.value : this.sentAt,
      body: data.body.present ? data.body.value : this.body,
      kind: data.kind.present ? data.kind.value : this.kind,
      state: data.state.present ? data.state.value : this.state,
      mine: data.mine.present ? data.mine.value : this.mine,
      nonce: data.nonce.present ? data.nonce.value : this.nonce,
      ciphertext: data.ciphertext.present
          ? data.ciphertext.value
          : this.ciphertext,
      signature: data.signature.present ? data.signature.value : this.signature,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessage(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('seq: $seq, ')
          ..write('epoch: $epoch, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('sentAt: $sentAt, ')
          ..write('body: $body, ')
          ..write('kind: $kind, ')
          ..write('state: $state, ')
          ..write('mine: $mine, ')
          ..write('nonce: $nonce, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('signature: $signature')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    messageId,
    seq,
    epoch,
    senderDeviceId,
    sentAt,
    body,
    kind,
    state,
    mine,
    $driftBlobEquality.hash(nonce),
    $driftBlobEquality.hash(ciphertext),
    $driftBlobEquality.hash(signature),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMessage &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.messageId == this.messageId &&
          other.seq == this.seq &&
          other.epoch == this.epoch &&
          other.senderDeviceId == this.senderDeviceId &&
          other.sentAt == this.sentAt &&
          other.body == this.body &&
          other.kind == this.kind &&
          other.state == this.state &&
          other.mine == this.mine &&
          $driftBlobEquality.equals(other.nonce, this.nonce) &&
          $driftBlobEquality.equals(other.ciphertext, this.ciphertext) &&
          $driftBlobEquality.equals(other.signature, this.signature));
}

class ChatMessagesCompanion extends UpdateCompanion<ChatMessage> {
  final Value<int> id;
  final Value<String> conversationId;
  final Value<String> messageId;
  final Value<int?> seq;
  final Value<int> epoch;
  final Value<String> senderDeviceId;
  final Value<int> sentAt;
  final Value<String?> body;
  final Value<int> kind;
  final Value<int> state;
  final Value<bool> mine;
  final Value<Uint8List?> nonce;
  final Value<Uint8List?> ciphertext;
  final Value<Uint8List?> signature;
  const ChatMessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.seq = const Value.absent(),
    this.epoch = const Value.absent(),
    this.senderDeviceId = const Value.absent(),
    this.sentAt = const Value.absent(),
    this.body = const Value.absent(),
    this.kind = const Value.absent(),
    this.state = const Value.absent(),
    this.mine = const Value.absent(),
    this.nonce = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.signature = const Value.absent(),
  });
  ChatMessagesCompanion.insert({
    this.id = const Value.absent(),
    required String conversationId,
    required String messageId,
    this.seq = const Value.absent(),
    required int epoch,
    required String senderDeviceId,
    required int sentAt,
    this.body = const Value.absent(),
    this.kind = const Value.absent(),
    required int state,
    required bool mine,
    this.nonce = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.signature = const Value.absent(),
  }) : conversationId = Value(conversationId),
       messageId = Value(messageId),
       epoch = Value(epoch),
       senderDeviceId = Value(senderDeviceId),
       sentAt = Value(sentAt),
       state = Value(state),
       mine = Value(mine);
  static Insertable<ChatMessage> custom({
    Expression<int>? id,
    Expression<String>? conversationId,
    Expression<String>? messageId,
    Expression<int>? seq,
    Expression<int>? epoch,
    Expression<String>? senderDeviceId,
    Expression<int>? sentAt,
    Expression<String>? body,
    Expression<int>? kind,
    Expression<int>? state,
    Expression<bool>? mine,
    Expression<Uint8List>? nonce,
    Expression<Uint8List>? ciphertext,
    Expression<Uint8List>? signature,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (messageId != null) 'message_id': messageId,
      if (seq != null) 'seq': seq,
      if (epoch != null) 'epoch': epoch,
      if (senderDeviceId != null) 'sender_device_id': senderDeviceId,
      if (sentAt != null) 'sent_at': sentAt,
      if (body != null) 'body': body,
      if (kind != null) 'kind': kind,
      if (state != null) 'state': state,
      if (mine != null) 'mine': mine,
      if (nonce != null) 'nonce': nonce,
      if (ciphertext != null) 'ciphertext': ciphertext,
      if (signature != null) 'signature': signature,
    });
  }

  ChatMessagesCompanion copyWith({
    Value<int>? id,
    Value<String>? conversationId,
    Value<String>? messageId,
    Value<int?>? seq,
    Value<int>? epoch,
    Value<String>? senderDeviceId,
    Value<int>? sentAt,
    Value<String?>? body,
    Value<int>? kind,
    Value<int>? state,
    Value<bool>? mine,
    Value<Uint8List?>? nonce,
    Value<Uint8List?>? ciphertext,
    Value<Uint8List?>? signature,
  }) {
    return ChatMessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      seq: seq ?? this.seq,
      epoch: epoch ?? this.epoch,
      senderDeviceId: senderDeviceId ?? this.senderDeviceId,
      sentAt: sentAt ?? this.sentAt,
      body: body ?? this.body,
      kind: kind ?? this.kind,
      state: state ?? this.state,
      mine: mine ?? this.mine,
      nonce: nonce ?? this.nonce,
      ciphertext: ciphertext ?? this.ciphertext,
      signature: signature ?? this.signature,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (senderDeviceId.present) {
      map['sender_device_id'] = Variable<String>(senderDeviceId.value);
    }
    if (sentAt.present) {
      map['sent_at'] = Variable<int>(sentAt.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (kind.present) {
      map['kind'] = Variable<int>(kind.value);
    }
    if (state.present) {
      map['state'] = Variable<int>(state.value);
    }
    if (mine.present) {
      map['mine'] = Variable<bool>(mine.value);
    }
    if (nonce.present) {
      map['nonce'] = Variable<Uint8List>(nonce.value);
    }
    if (ciphertext.present) {
      map['ciphertext'] = Variable<Uint8List>(ciphertext.value);
    }
    if (signature.present) {
      map['signature'] = Variable<Uint8List>(signature.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('seq: $seq, ')
          ..write('epoch: $epoch, ')
          ..write('senderDeviceId: $senderDeviceId, ')
          ..write('sentAt: $sentAt, ')
          ..write('body: $body, ')
          ..write('kind: $kind, ')
          ..write('state: $state, ')
          ..write('mine: $mine, ')
          ..write('nonce: $nonce, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('signature: $signature')
          ..write(')'))
        .toString();
  }
}

class $ChatMetaTable extends ChatMeta
    with TableInfo<$ChatMetaTable, ChatMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _kMeta = const VerificationMeta('k');
  @override
  late final GeneratedColumn<String> k = GeneratedColumn<String>(
    'k',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vMeta = const VerificationMeta('v');
  @override
  late final GeneratedColumn<String> v = GeneratedColumn<String>(
    'v',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [k, v];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChatMetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('k')) {
      context.handle(_kMeta, k.isAcceptableOrUnknown(data['k']!, _kMeta));
    } else if (isInserting) {
      context.missing(_kMeta);
    }
    if (data.containsKey('v')) {
      context.handle(_vMeta, v.isAcceptableOrUnknown(data['v']!, _vMeta));
    } else if (isInserting) {
      context.missing(_vMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {k};
  @override
  ChatMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMetaData(
      k: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}k'],
      )!,
      v: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}v'],
      )!,
    );
  }

  @override
  $ChatMetaTable createAlias(String alias) {
    return $ChatMetaTable(attachedDatabase, alias);
  }
}

class ChatMetaData extends DataClass implements Insertable<ChatMetaData> {
  final String k;
  final String v;
  const ChatMetaData({required this.k, required this.v});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['k'] = Variable<String>(k);
    map['v'] = Variable<String>(v);
    return map;
  }

  ChatMetaCompanion toCompanion(bool nullToAbsent) {
    return ChatMetaCompanion(k: Value(k), v: Value(v));
  }

  factory ChatMetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMetaData(
      k: serializer.fromJson<String>(json['k']),
      v: serializer.fromJson<String>(json['v']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'k': serializer.toJson<String>(k),
      'v': serializer.toJson<String>(v),
    };
  }

  ChatMetaData copyWith({String? k, String? v}) =>
      ChatMetaData(k: k ?? this.k, v: v ?? this.v);
  ChatMetaData copyWithCompanion(ChatMetaCompanion data) {
    return ChatMetaData(
      k: data.k.present ? data.k.value : this.k,
      v: data.v.present ? data.v.value : this.v,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMetaData(')
          ..write('k: $k, ')
          ..write('v: $v')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(k, v);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMetaData && other.k == this.k && other.v == this.v);
}

class ChatMetaCompanion extends UpdateCompanion<ChatMetaData> {
  final Value<String> k;
  final Value<String> v;
  final Value<int> rowid;
  const ChatMetaCompanion({
    this.k = const Value.absent(),
    this.v = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChatMetaCompanion.insert({
    required String k,
    required String v,
    this.rowid = const Value.absent(),
  }) : k = Value(k),
       v = Value(v);
  static Insertable<ChatMetaData> custom({
    Expression<String>? k,
    Expression<String>? v,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (k != null) 'k': k,
      if (v != null) 'v': v,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChatMetaCompanion copyWith({
    Value<String>? k,
    Value<String>? v,
    Value<int>? rowid,
  }) {
    return ChatMetaCompanion(
      k: k ?? this.k,
      v: v ?? this.v,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (k.present) {
      map['k'] = Variable<String>(k.value);
    }
    if (v.present) {
      map['v'] = Variable<String>(v.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMetaCompanion(')
          ..write('k: $k, ')
          ..write('v: $v, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttachmentsTable extends Attachments
    with TableInfo<$AttachmentsTable, Attachment> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttachmentsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<Uint8List> data = GeneratedColumn<Uint8List>(
    'data',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [conversationId, messageId, data];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attachments';
  @override
  VerificationContext validateIntegrity(
    Insertable<Attachment> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, messageId};
  @override
  Attachment map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Attachment(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}data'],
      ),
    );
  }

  @override
  $AttachmentsTable createAlias(String alias) {
    return $AttachmentsTable(attachedDatabase, alias);
  }
}

class Attachment extends DataClass implements Insertable<Attachment> {
  final String conversationId;
  final String messageId;
  final Uint8List? data;
  const Attachment({
    required this.conversationId,
    required this.messageId,
    this.data,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['message_id'] = Variable<String>(messageId);
    if (!nullToAbsent || data != null) {
      map['data'] = Variable<Uint8List>(data);
    }
    return map;
  }

  AttachmentsCompanion toCompanion(bool nullToAbsent) {
    return AttachmentsCompanion(
      conversationId: Value(conversationId),
      messageId: Value(messageId),
      data: data == null && nullToAbsent ? const Value.absent() : Value(data),
    );
  }

  factory Attachment.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Attachment(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      data: serializer.fromJson<Uint8List?>(json['data']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'messageId': serializer.toJson<String>(messageId),
      'data': serializer.toJson<Uint8List?>(data),
    };
  }

  Attachment copyWith({
    String? conversationId,
    String? messageId,
    Value<Uint8List?> data = const Value.absent(),
  }) => Attachment(
    conversationId: conversationId ?? this.conversationId,
    messageId: messageId ?? this.messageId,
    data: data.present ? data.value : this.data,
  );
  Attachment copyWithCompanion(AttachmentsCompanion data) {
    return Attachment(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      data: data.data.present ? data.data.value : this.data,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Attachment(')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('data: $data')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(conversationId, messageId, $driftBlobEquality.hash(data));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Attachment &&
          other.conversationId == this.conversationId &&
          other.messageId == this.messageId &&
          $driftBlobEquality.equals(other.data, this.data));
}

class AttachmentsCompanion extends UpdateCompanion<Attachment> {
  final Value<String> conversationId;
  final Value<String> messageId;
  final Value<Uint8List?> data;
  final Value<int> rowid;
  const AttachmentsCompanion({
    this.conversationId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttachmentsCompanion.insert({
    required String conversationId,
    required String messageId,
    this.data = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       messageId = Value(messageId);
  static Insertable<Attachment> custom({
    Expression<String>? conversationId,
    Expression<String>? messageId,
    Expression<Uint8List>? data,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (messageId != null) 'message_id': messageId,
      if (data != null) 'data': data,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttachmentsCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? messageId,
    Value<Uint8List?>? data,
    Value<int>? rowid,
  }) {
    return AttachmentsCompanion(
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      data: data ?? this.data,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (data.present) {
      map['data'] = Variable<Uint8List>(data.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttachmentsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('messageId: $messageId, ')
          ..write('data: $data, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupAnchorsTable extends GroupAnchors
    with TableInfo<$GroupAnchorsTable, GroupAnchor> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupAnchorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nMeta = const VerificationMeta('n');
  @override
  late final GeneratedColumn<int> n = GeneratedColumn<int>(
    'n',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hashMeta = const VerificationMeta('hash');
  @override
  late final GeneratedColumn<Uint8List> hash = GeneratedColumn<Uint8List>(
    'hash',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [conversationId, n, hash];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_anchors';
  @override
  VerificationContext validateIntegrity(
    Insertable<GroupAnchor> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('n')) {
      context.handle(_nMeta, n.isAcceptableOrUnknown(data['n']!, _nMeta));
    } else if (isInserting) {
      context.missing(_nMeta);
    }
    if (data.containsKey('hash')) {
      context.handle(
        _hashMeta,
        hash.isAcceptableOrUnknown(data['hash']!, _hashMeta),
      );
    } else if (isInserting) {
      context.missing(_hashMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  GroupAnchor map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GroupAnchor(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      n: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}n'],
      )!,
      hash: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}hash'],
      )!,
    );
  }

  @override
  $GroupAnchorsTable createAlias(String alias) {
    return $GroupAnchorsTable(attachedDatabase, alias);
  }
}

class GroupAnchor extends DataClass implements Insertable<GroupAnchor> {
  final String conversationId;
  final int n;
  final Uint8List hash;
  const GroupAnchor({
    required this.conversationId,
    required this.n,
    required this.hash,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['n'] = Variable<int>(n);
    map['hash'] = Variable<Uint8List>(hash);
    return map;
  }

  GroupAnchorsCompanion toCompanion(bool nullToAbsent) {
    return GroupAnchorsCompanion(
      conversationId: Value(conversationId),
      n: Value(n),
      hash: Value(hash),
    );
  }

  factory GroupAnchor.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GroupAnchor(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      n: serializer.fromJson<int>(json['n']),
      hash: serializer.fromJson<Uint8List>(json['hash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'n': serializer.toJson<int>(n),
      'hash': serializer.toJson<Uint8List>(hash),
    };
  }

  GroupAnchor copyWith({String? conversationId, int? n, Uint8List? hash}) =>
      GroupAnchor(
        conversationId: conversationId ?? this.conversationId,
        n: n ?? this.n,
        hash: hash ?? this.hash,
      );
  GroupAnchor copyWithCompanion(GroupAnchorsCompanion data) {
    return GroupAnchor(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      n: data.n.present ? data.n.value : this.n,
      hash: data.hash.present ? data.hash.value : this.hash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GroupAnchor(')
          ..write('conversationId: $conversationId, ')
          ..write('n: $n, ')
          ..write('hash: $hash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(conversationId, n, $driftBlobEquality.hash(hash));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GroupAnchor &&
          other.conversationId == this.conversationId &&
          other.n == this.n &&
          $driftBlobEquality.equals(other.hash, this.hash));
}

class GroupAnchorsCompanion extends UpdateCompanion<GroupAnchor> {
  final Value<String> conversationId;
  final Value<int> n;
  final Value<Uint8List> hash;
  final Value<int> rowid;
  const GroupAnchorsCompanion({
    this.conversationId = const Value.absent(),
    this.n = const Value.absent(),
    this.hash = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupAnchorsCompanion.insert({
    required String conversationId,
    required int n,
    required Uint8List hash,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       n = Value(n),
       hash = Value(hash);
  static Insertable<GroupAnchor> custom({
    Expression<String>? conversationId,
    Expression<int>? n,
    Expression<Uint8List>? hash,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (n != null) 'n': n,
      if (hash != null) 'hash': hash,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupAnchorsCompanion copyWith({
    Value<String>? conversationId,
    Value<int>? n,
    Value<Uint8List>? hash,
    Value<int>? rowid,
  }) {
    return GroupAnchorsCompanion(
      conversationId: conversationId ?? this.conversationId,
      n: n ?? this.n,
      hash: hash ?? this.hash,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (n.present) {
      map['n'] = Variable<int>(n.value);
    }
    if (hash.present) {
      map['hash'] = Variable<Uint8List>(hash.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupAnchorsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('n: $n, ')
          ..write('hash: $hash, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HiddenConversationsTable extends HiddenConversations
    with TableInfo<$HiddenConversationsTable, HiddenConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HiddenConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pubMeta = const VerificationMeta('pub');
  @override
  late final GeneratedColumn<Uint8List> pub = GeneratedColumn<Uint8List>(
    'pub',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wrappedMeta = const VerificationMeta(
    'wrapped',
  );
  @override
  late final GeneratedColumn<String> wrapped = GeneratedColumn<String>(
    'wrapped',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [conversationId, pub, wrapped];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'hidden_conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<HiddenConversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('pub')) {
      context.handle(
        _pubMeta,
        pub.isAcceptableOrUnknown(data['pub']!, _pubMeta),
      );
    } else if (isInserting) {
      context.missing(_pubMeta);
    }
    if (data.containsKey('wrapped')) {
      context.handle(
        _wrappedMeta,
        wrapped.isAcceptableOrUnknown(data['wrapped']!, _wrappedMeta),
      );
    } else if (isInserting) {
      context.missing(_wrappedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  HiddenConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HiddenConversation(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      pub: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}pub'],
      )!,
      wrapped: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wrapped'],
      )!,
    );
  }

  @override
  $HiddenConversationsTable createAlias(String alias) {
    return $HiddenConversationsTable(attachedDatabase, alias);
  }
}

class HiddenConversation extends DataClass
    implements Insertable<HiddenConversation> {
  final String conversationId;
  final Uint8List pub;

  /// Chave privada embrulhada pela senha da conversa (`Vault.wrapWithPassword`).
  final String wrapped;
  const HiddenConversation({
    required this.conversationId,
    required this.pub,
    required this.wrapped,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['pub'] = Variable<Uint8List>(pub);
    map['wrapped'] = Variable<String>(wrapped);
    return map;
  }

  HiddenConversationsCompanion toCompanion(bool nullToAbsent) {
    return HiddenConversationsCompanion(
      conversationId: Value(conversationId),
      pub: Value(pub),
      wrapped: Value(wrapped),
    );
  }

  factory HiddenConversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HiddenConversation(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      pub: serializer.fromJson<Uint8List>(json['pub']),
      wrapped: serializer.fromJson<String>(json['wrapped']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'pub': serializer.toJson<Uint8List>(pub),
      'wrapped': serializer.toJson<String>(wrapped),
    };
  }

  HiddenConversation copyWith({
    String? conversationId,
    Uint8List? pub,
    String? wrapped,
  }) => HiddenConversation(
    conversationId: conversationId ?? this.conversationId,
    pub: pub ?? this.pub,
    wrapped: wrapped ?? this.wrapped,
  );
  HiddenConversation copyWithCompanion(HiddenConversationsCompanion data) {
    return HiddenConversation(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      pub: data.pub.present ? data.pub.value : this.pub,
      wrapped: data.wrapped.present ? data.wrapped.value : this.wrapped,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HiddenConversation(')
          ..write('conversationId: $conversationId, ')
          ..write('pub: $pub, ')
          ..write('wrapped: $wrapped')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(conversationId, $driftBlobEquality.hash(pub), wrapped);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HiddenConversation &&
          other.conversationId == this.conversationId &&
          $driftBlobEquality.equals(other.pub, this.pub) &&
          other.wrapped == this.wrapped);
}

class HiddenConversationsCompanion extends UpdateCompanion<HiddenConversation> {
  final Value<String> conversationId;
  final Value<Uint8List> pub;
  final Value<String> wrapped;
  final Value<int> rowid;
  const HiddenConversationsCompanion({
    this.conversationId = const Value.absent(),
    this.pub = const Value.absent(),
    this.wrapped = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HiddenConversationsCompanion.insert({
    required String conversationId,
    required Uint8List pub,
    required String wrapped,
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       pub = Value(pub),
       wrapped = Value(wrapped);
  static Insertable<HiddenConversation> custom({
    Expression<String>? conversationId,
    Expression<Uint8List>? pub,
    Expression<String>? wrapped,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (pub != null) 'pub': pub,
      if (wrapped != null) 'wrapped': wrapped,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HiddenConversationsCompanion copyWith({
    Value<String>? conversationId,
    Value<Uint8List>? pub,
    Value<String>? wrapped,
    Value<int>? rowid,
  }) {
    return HiddenConversationsCompanion(
      conversationId: conversationId ?? this.conversationId,
      pub: pub ?? this.pub,
      wrapped: wrapped ?? this.wrapped,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (pub.present) {
      map['pub'] = Variable<Uint8List>(pub.value);
    }
    if (wrapped.present) {
      map['wrapped'] = Variable<String>(wrapped.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HiddenConversationsCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('pub: $pub, ')
          ..write('wrapped: $wrapped, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $LocalProfilesTable localProfiles = $LocalProfilesTable(this);
  late final $DirUsersTable dirUsers = $DirUsersTable(this);
  late final $KnownDevicesTable knownDevices = $KnownDevicesTable(this);
  late final $SeenKeysTable seenKeys = $SeenKeysTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $EpochKeysTable epochKeys = $EpochKeysTable(this);
  late final $ChatMessagesTable chatMessages = $ChatMessagesTable(this);
  late final $ChatMetaTable chatMeta = $ChatMetaTable(this);
  late final $AttachmentsTable attachments = $AttachmentsTable(this);
  late final $GroupAnchorsTable groupAnchors = $GroupAnchorsTable(this);
  late final $HiddenConversationsTable hiddenConversations =
      $HiddenConversationsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localProfiles,
    dirUsers,
    knownDevices,
    seenKeys,
    conversations,
    epochKeys,
    chatMessages,
    chatMeta,
    attachments,
    groupAnchors,
    hiddenConversations,
  ];
}

typedef $$LocalProfilesTableCreateCompanionBuilder =
    LocalProfilesCompanion Function({
      Value<int> id,
      required String displayName,
      required String status,
    });
typedef $$LocalProfilesTableUpdateCompanionBuilder =
    LocalProfilesCompanion Function({
      Value<int> id,
      Value<String> displayName,
      Value<String> status,
    });

class $$LocalProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalProfilesTable> {
  $$LocalProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalProfilesTable> {
  $$LocalProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalProfilesTable> {
  $$LocalProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);
}

class $$LocalProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalProfilesTable,
          LocalProfile,
          $$LocalProfilesTableFilterComposer,
          $$LocalProfilesTableOrderingComposer,
          $$LocalProfilesTableAnnotationComposer,
          $$LocalProfilesTableCreateCompanionBuilder,
          $$LocalProfilesTableUpdateCompanionBuilder,
          (
            LocalProfile,
            BaseReferences<_$AppDatabase, $LocalProfilesTable, LocalProfile>,
          ),
          LocalProfile,
          PrefetchHooks Function()
        > {
  $$LocalProfilesTableTableManager(_$AppDatabase db, $LocalProfilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> status = const Value.absent(),
              }) => LocalProfilesCompanion(
                id: id,
                displayName: displayName,
                status: status,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String displayName,
                required String status,
              }) => LocalProfilesCompanion.insert(
                id: id,
                displayName: displayName,
                status: status,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalProfilesTable, LocalProfile>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalProfilesTable,
                    LocalProfile
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalProfilesTable,
      LocalProfile,
      $$LocalProfilesTableFilterComposer,
      $$LocalProfilesTableOrderingComposer,
      $$LocalProfilesTableAnnotationComposer,
      $$LocalProfilesTableCreateCompanionBuilder,
      $$LocalProfilesTableUpdateCompanionBuilder,
      (
        LocalProfile,
        BaseReferences<_$AppDatabase, $LocalProfilesTable, LocalProfile>,
      ),
      LocalProfile,
      PrefetchHooks Function()
    >;
typedef $$DirUsersTableCreateCompanionBuilder = DirUsersCompanion Function({
  required String userId,
  required String adminLabel,
  required String displayName,
  required String status,
  Value<int> rowid,
});
typedef $$DirUsersTableUpdateCompanionBuilder = DirUsersCompanion Function({
  Value<String> userId,
  Value<String> adminLabel,
  Value<String> displayName,
  Value<String> status,
  Value<int> rowid,
});

class $$DirUsersTableFilterComposer
    extends Composer<_$AppDatabase, $DirUsersTable> {
  $$DirUsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get adminLabel => $composableBuilder(
    column: $table.adminLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DirUsersTableOrderingComposer
    extends Composer<_$AppDatabase, $DirUsersTable> {
  $$DirUsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get adminLabel => $composableBuilder(
    column: $table.adminLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DirUsersTableAnnotationComposer
    extends Composer<_$AppDatabase, $DirUsersTable> {
  $$DirUsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get adminLabel => $composableBuilder(
    column: $table.adminLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);
}

class $$DirUsersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DirUsersTable,
          DirUser,
          $$DirUsersTableFilterComposer,
          $$DirUsersTableOrderingComposer,
          $$DirUsersTableAnnotationComposer,
          $$DirUsersTableCreateCompanionBuilder,
          $$DirUsersTableUpdateCompanionBuilder,
          (DirUser, BaseReferences<_$AppDatabase, $DirUsersTable, DirUser>),
          DirUser,
          PrefetchHooks Function()
        > {
  $$DirUsersTableTableManager(_$AppDatabase db, $DirUsersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DirUsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DirUsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DirUsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<String> adminLabel = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DirUsersCompanion(
                userId: userId,
                adminLabel: adminLabel,
                displayName: displayName,
                status: status,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required String adminLabel,
                required String displayName,
                required String status,
                Value<int> rowid = const Value.absent(),
              }) => DirUsersCompanion.insert(
                userId: userId,
                adminLabel: adminLabel,
                displayName: displayName,
                status: status,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DirUsersTable, DirUser>(table),
                  BaseReferences<_$AppDatabase, $DirUsersTable, DirUser>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DirUsersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DirUsersTable,
      DirUser,
      $$DirUsersTableFilterComposer,
      $$DirUsersTableOrderingComposer,
      $$DirUsersTableAnnotationComposer,
      $$DirUsersTableCreateCompanionBuilder,
      $$DirUsersTableUpdateCompanionBuilder,
      (DirUser, BaseReferences<_$AppDatabase, $DirUsersTable, DirUser>),
      DirUser,
      PrefetchHooks Function()
    >;
typedef $$KnownDevicesTableCreateCompanionBuilder =
    KnownDevicesCompanion Function({
      required String deviceId,
      required String userId,
      required String certJson,
      required bool active,
      Value<int> rowid,
    });
typedef $$KnownDevicesTableUpdateCompanionBuilder =
    KnownDevicesCompanion Function({
      Value<String> deviceId,
      Value<String> userId,
      Value<String> certJson,
      Value<bool> active,
      Value<int> rowid,
    });

class $$KnownDevicesTableFilterComposer
    extends Composer<_$AppDatabase, $KnownDevicesTable> {
  $$KnownDevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get certJson => $composableBuilder(
    column: $table.certJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get active => $composableBuilder(
    column: $table.active,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnownDevicesTableOrderingComposer
    extends Composer<_$AppDatabase, $KnownDevicesTable> {
  $$KnownDevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get certJson => $composableBuilder(
    column: $table.certJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get active => $composableBuilder(
    column: $table.active,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnownDevicesTableAnnotationComposer
    extends Composer<_$AppDatabase, $KnownDevicesTable> {
  $$KnownDevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get certJson =>
      $composableBuilder(column: $table.certJson, builder: (column) => column);

  GeneratedColumn<bool> get active =>
      $composableBuilder(column: $table.active, builder: (column) => column);
}

class $$KnownDevicesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KnownDevicesTable,
          KnownDevice,
          $$KnownDevicesTableFilterComposer,
          $$KnownDevicesTableOrderingComposer,
          $$KnownDevicesTableAnnotationComposer,
          $$KnownDevicesTableCreateCompanionBuilder,
          $$KnownDevicesTableUpdateCompanionBuilder,
          (
            KnownDevice,
            BaseReferences<_$AppDatabase, $KnownDevicesTable, KnownDevice>,
          ),
          KnownDevice,
          PrefetchHooks Function()
        > {
  $$KnownDevicesTableTableManager(_$AppDatabase db, $KnownDevicesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnownDevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnownDevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnownDevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> deviceId = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<String> certJson = const Value.absent(),
                Value<bool> active = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnownDevicesCompanion(
                deviceId: deviceId,
                userId: userId,
                certJson: certJson,
                active: active,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String deviceId,
                required String userId,
                required String certJson,
                required bool active,
                Value<int> rowid = const Value.absent(),
              }) => KnownDevicesCompanion.insert(
                deviceId: deviceId,
                userId: userId,
                certJson: certJson,
                active: active,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KnownDevicesTable, KnownDevice>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $KnownDevicesTable,
                    KnownDevice
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnownDevicesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KnownDevicesTable,
      KnownDevice,
      $$KnownDevicesTableFilterComposer,
      $$KnownDevicesTableOrderingComposer,
      $$KnownDevicesTableAnnotationComposer,
      $$KnownDevicesTableCreateCompanionBuilder,
      $$KnownDevicesTableUpdateCompanionBuilder,
      (
        KnownDevice,
        BaseReferences<_$AppDatabase, $KnownDevicesTable, KnownDevice>,
      ),
      KnownDevice,
      PrefetchHooks Function()
    >;
typedef $$SeenKeysTableCreateCompanionBuilder = SeenKeysCompanion Function({
  required String userId,
  required String signPub,
  required bool present,
  Value<int?> noticedAt,
  Value<int> rowid,
});
typedef $$SeenKeysTableUpdateCompanionBuilder = SeenKeysCompanion Function({
  Value<String> userId,
  Value<String> signPub,
  Value<bool> present,
  Value<int?> noticedAt,
  Value<int> rowid,
});

class $$SeenKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SeenKeysTable> {
  $$SeenKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signPub => $composableBuilder(
    column: $table.signPub,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get present => $composableBuilder(
    column: $table.present,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get noticedAt => $composableBuilder(
    column: $table.noticedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SeenKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SeenKeysTable> {
  $$SeenKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signPub => $composableBuilder(
    column: $table.signPub,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get present => $composableBuilder(
    column: $table.present,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get noticedAt => $composableBuilder(
    column: $table.noticedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SeenKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SeenKeysTable> {
  $$SeenKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get signPub =>
      $composableBuilder(column: $table.signPub, builder: (column) => column);

  GeneratedColumn<bool> get present =>
      $composableBuilder(column: $table.present, builder: (column) => column);

  GeneratedColumn<int> get noticedAt =>
      $composableBuilder(column: $table.noticedAt, builder: (column) => column);
}

class $$SeenKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SeenKeysTable,
          SeenKey,
          $$SeenKeysTableFilterComposer,
          $$SeenKeysTableOrderingComposer,
          $$SeenKeysTableAnnotationComposer,
          $$SeenKeysTableCreateCompanionBuilder,
          $$SeenKeysTableUpdateCompanionBuilder,
          (SeenKey, BaseReferences<_$AppDatabase, $SeenKeysTable, SeenKey>),
          SeenKey,
          PrefetchHooks Function()
        > {
  $$SeenKeysTableTableManager(_$AppDatabase db, $SeenKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SeenKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SeenKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SeenKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<String> signPub = const Value.absent(),
                Value<bool> present = const Value.absent(),
                Value<int?> noticedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SeenKeysCompanion(
                userId: userId,
                signPub: signPub,
                present: present,
                noticedAt: noticedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required String signPub,
                required bool present,
                Value<int?> noticedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SeenKeysCompanion.insert(
                userId: userId,
                signPub: signPub,
                present: present,
                noticedAt: noticedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SeenKeysTable, SeenKey>(table),
                  BaseReferences<_$AppDatabase, $SeenKeysTable, SeenKey>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SeenKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SeenKeysTable,
      SeenKey,
      $$SeenKeysTableFilterComposer,
      $$SeenKeysTableOrderingComposer,
      $$SeenKeysTableAnnotationComposer,
      $$SeenKeysTableCreateCompanionBuilder,
      $$SeenKeysTableUpdateCompanionBuilder,
      (SeenKey, BaseReferences<_$AppDatabase, $SeenKeysTable, SeenKey>),
      SeenKey,
      PrefetchHooks Function()
    >;
typedef $$ConversationsTableCreateCompanionBuilder =
    ConversationsCompanion Function({
      required String conversationId,
      required String peerUserId,
      required String membersJson,
      required int latestEpoch,
      required int syncedSeq,
      Value<int> rowid,
    });
typedef $$ConversationsTableUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> conversationId,
      Value<String> peerUserId,
      Value<String> membersJson,
      Value<int> latestEpoch,
      Value<int> syncedSeq,
      Value<int> rowid,
    });

class $$ConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get membersJson => $composableBuilder(
    column: $table.membersJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get latestEpoch => $composableBuilder(
    column: $table.latestEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get membersJson => $composableBuilder(
    column: $table.membersJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get latestEpoch => $composableBuilder(
    column: $table.latestEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get membersJson => $composableBuilder(
    column: $table.membersJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get latestEpoch => $composableBuilder(
    column: $table.latestEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);
}

class $$ConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationsTable,
          Conversation,
          $$ConversationsTableFilterComposer,
          $$ConversationsTableOrderingComposer,
          $$ConversationsTableAnnotationComposer,
          $$ConversationsTableCreateCompanionBuilder,
          $$ConversationsTableUpdateCompanionBuilder,
          (
            Conversation,
            BaseReferences<_$AppDatabase, $ConversationsTable, Conversation>,
          ),
          Conversation,
          PrefetchHooks Function()
        > {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> peerUserId = const Value.absent(),
                Value<String> membersJson = const Value.absent(),
                Value<int> latestEpoch = const Value.absent(),
                Value<int> syncedSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                conversationId: conversationId,
                peerUserId: peerUserId,
                membersJson: membersJson,
                latestEpoch: latestEpoch,
                syncedSeq: syncedSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String peerUserId,
                required String membersJson,
                required int latestEpoch,
                required int syncedSeq,
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                conversationId: conversationId,
                peerUserId: peerUserId,
                membersJson: membersJson,
                latestEpoch: latestEpoch,
                syncedSeq: syncedSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConversationsTable, Conversation>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ConversationsTable,
                    Conversation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationsTable,
      Conversation,
      $$ConversationsTableFilterComposer,
      $$ConversationsTableOrderingComposer,
      $$ConversationsTableAnnotationComposer,
      $$ConversationsTableCreateCompanionBuilder,
      $$ConversationsTableUpdateCompanionBuilder,
      (
        Conversation,
        BaseReferences<_$AppDatabase, $ConversationsTable, Conversation>,
      ),
      Conversation,
      PrefetchHooks Function()
    >;
typedef $$EpochKeysTableCreateCompanionBuilder = EpochKeysCompanion Function({
  required String conversationId,
  required int epoch,
  required Uint8List key,
  required String recipientsJson,
  Value<int> rowid,
});
typedef $$EpochKeysTableUpdateCompanionBuilder = EpochKeysCompanion Function({
  Value<String> conversationId,
  Value<int> epoch,
  Value<Uint8List> key,
  Value<String> recipientsJson,
  Value<int> rowid,
});

class $$EpochKeysTableFilterComposer
    extends Composer<_$AppDatabase, $EpochKeysTable> {
  $$EpochKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EpochKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $EpochKeysTable> {
  $$EpochKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EpochKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $EpochKeysTable> {
  $$EpochKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<Uint8List> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get recipientsJson => $composableBuilder(
    column: $table.recipientsJson,
    builder: (column) => column,
  );
}

class $$EpochKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $EpochKeysTable,
          EpochKey,
          $$EpochKeysTableFilterComposer,
          $$EpochKeysTableOrderingComposer,
          $$EpochKeysTableAnnotationComposer,
          $$EpochKeysTableCreateCompanionBuilder,
          $$EpochKeysTableUpdateCompanionBuilder,
          (EpochKey, BaseReferences<_$AppDatabase, $EpochKeysTable, EpochKey>),
          EpochKey,
          PrefetchHooks Function()
        > {
  $$EpochKeysTableTableManager(_$AppDatabase db, $EpochKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EpochKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EpochKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EpochKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<Uint8List> key = const Value.absent(),
                Value<String> recipientsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EpochKeysCompanion(
                conversationId: conversationId,
                epoch: epoch,
                key: key,
                recipientsJson: recipientsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required int epoch,
                required Uint8List key,
                required String recipientsJson,
                Value<int> rowid = const Value.absent(),
              }) => EpochKeysCompanion.insert(
                conversationId: conversationId,
                epoch: epoch,
                key: key,
                recipientsJson: recipientsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EpochKeysTable, EpochKey>(table),
                  BaseReferences<_$AppDatabase, $EpochKeysTable, EpochKey>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EpochKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $EpochKeysTable,
      EpochKey,
      $$EpochKeysTableFilterComposer,
      $$EpochKeysTableOrderingComposer,
      $$EpochKeysTableAnnotationComposer,
      $$EpochKeysTableCreateCompanionBuilder,
      $$EpochKeysTableUpdateCompanionBuilder,
      (EpochKey, BaseReferences<_$AppDatabase, $EpochKeysTable, EpochKey>),
      EpochKey,
      PrefetchHooks Function()
    >;
typedef $$ChatMessagesTableCreateCompanionBuilder =
    ChatMessagesCompanion Function({
      Value<int> id,
      required String conversationId,
      required String messageId,
      Value<int?> seq,
      required int epoch,
      required String senderDeviceId,
      required int sentAt,
      Value<String?> body,
      Value<int> kind,
      required int state,
      required bool mine,
      Value<Uint8List?> nonce,
      Value<Uint8List?> ciphertext,
      Value<Uint8List?> signature,
    });
typedef $$ChatMessagesTableUpdateCompanionBuilder =
    ChatMessagesCompanion Function({
      Value<int> id,
      Value<String> conversationId,
      Value<String> messageId,
      Value<int?> seq,
      Value<int> epoch,
      Value<String> senderDeviceId,
      Value<int> sentAt,
      Value<String?> body,
      Value<int> kind,
      Value<int> state,
      Value<bool> mine,
      Value<Uint8List?> nonce,
      Value<Uint8List?> ciphertext,
      Value<Uint8List?> signature,
    });

class $$ChatMessagesTableFilterComposer
    extends Composer<_$AppDatabase, $ChatMessagesTable> {
  $$ChatMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sentAt => $composableBuilder(
    column: $table.sentAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get mine => $composableBuilder(
    column: $table.mine,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get signature => $composableBuilder(
    column: $table.signature,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChatMessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatMessagesTable> {
  $$ChatMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sentAt => $composableBuilder(
    column: $table.sentAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get mine => $composableBuilder(
    column: $table.mine,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get signature => $composableBuilder(
    column: $table.signature,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChatMessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatMessagesTable> {
  $$ChatMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<String> get senderDeviceId => $composableBuilder(
    column: $table.senderDeviceId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sentAt =>
      $composableBuilder(column: $table.sentAt, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<int> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<bool> get mine =>
      $composableBuilder(column: $table.mine, builder: (column) => column);

  GeneratedColumn<Uint8List> get nonce =>
      $composableBuilder(column: $table.nonce, builder: (column) => column);

  GeneratedColumn<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get signature =>
      $composableBuilder(column: $table.signature, builder: (column) => column);
}

class $$ChatMessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatMessagesTable,
          ChatMessage,
          $$ChatMessagesTableFilterComposer,
          $$ChatMessagesTableOrderingComposer,
          $$ChatMessagesTableAnnotationComposer,
          $$ChatMessagesTableCreateCompanionBuilder,
          $$ChatMessagesTableUpdateCompanionBuilder,
          (
            ChatMessage,
            BaseReferences<_$AppDatabase, $ChatMessagesTable, ChatMessage>,
          ),
          ChatMessage,
          PrefetchHooks Function()
        > {
  $$ChatMessagesTableTableManager(_$AppDatabase db, $ChatMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<int?> seq = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<String> senderDeviceId = const Value.absent(),
                Value<int> sentAt = const Value.absent(),
                Value<String?> body = const Value.absent(),
                Value<int> kind = const Value.absent(),
                Value<int> state = const Value.absent(),
                Value<bool> mine = const Value.absent(),
                Value<Uint8List?> nonce = const Value.absent(),
                Value<Uint8List?> ciphertext = const Value.absent(),
                Value<Uint8List?> signature = const Value.absent(),
              }) => ChatMessagesCompanion(
                id: id,
                conversationId: conversationId,
                messageId: messageId,
                seq: seq,
                epoch: epoch,
                senderDeviceId: senderDeviceId,
                sentAt: sentAt,
                body: body,
                kind: kind,
                state: state,
                mine: mine,
                nonce: nonce,
                ciphertext: ciphertext,
                signature: signature,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String conversationId,
                required String messageId,
                Value<int?> seq = const Value.absent(),
                required int epoch,
                required String senderDeviceId,
                required int sentAt,
                Value<String?> body = const Value.absent(),
                Value<int> kind = const Value.absent(),
                required int state,
                required bool mine,
                Value<Uint8List?> nonce = const Value.absent(),
                Value<Uint8List?> ciphertext = const Value.absent(),
                Value<Uint8List?> signature = const Value.absent(),
              }) => ChatMessagesCompanion.insert(
                id: id,
                conversationId: conversationId,
                messageId: messageId,
                seq: seq,
                epoch: epoch,
                senderDeviceId: senderDeviceId,
                sentAt: sentAt,
                body: body,
                kind: kind,
                state: state,
                mine: mine,
                nonce: nonce,
                ciphertext: ciphertext,
                signature: signature,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChatMessagesTable, ChatMessage>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ChatMessagesTable,
                    ChatMessage
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChatMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatMessagesTable,
      ChatMessage,
      $$ChatMessagesTableFilterComposer,
      $$ChatMessagesTableOrderingComposer,
      $$ChatMessagesTableAnnotationComposer,
      $$ChatMessagesTableCreateCompanionBuilder,
      $$ChatMessagesTableUpdateCompanionBuilder,
      (
        ChatMessage,
        BaseReferences<_$AppDatabase, $ChatMessagesTable, ChatMessage>,
      ),
      ChatMessage,
      PrefetchHooks Function()
    >;
typedef $$ChatMetaTableCreateCompanionBuilder = ChatMetaCompanion Function({
  required String k,
  required String v,
  Value<int> rowid,
});
typedef $$ChatMetaTableUpdateCompanionBuilder = ChatMetaCompanion Function({
  Value<String> k,
  Value<String> v,
  Value<int> rowid,
});

class $$ChatMetaTableFilterComposer
    extends Composer<_$AppDatabase, $ChatMetaTable> {
  $$ChatMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get k => $composableBuilder(
    column: $table.k,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get v => $composableBuilder(
    column: $table.v,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChatMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $ChatMetaTable> {
  $$ChatMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get k => $composableBuilder(
    column: $table.k,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get v => $composableBuilder(
    column: $table.v,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChatMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $ChatMetaTable> {
  $$ChatMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get k =>
      $composableBuilder(column: $table.k, builder: (column) => column);

  GeneratedColumn<String> get v =>
      $composableBuilder(column: $table.v, builder: (column) => column);
}

class $$ChatMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ChatMetaTable,
          ChatMetaData,
          $$ChatMetaTableFilterComposer,
          $$ChatMetaTableOrderingComposer,
          $$ChatMetaTableAnnotationComposer,
          $$ChatMetaTableCreateCompanionBuilder,
          $$ChatMetaTableUpdateCompanionBuilder,
          (
            ChatMetaData,
            BaseReferences<_$AppDatabase, $ChatMetaTable, ChatMetaData>,
          ),
          ChatMetaData,
          PrefetchHooks Function()
        > {
  $$ChatMetaTableTableManager(_$AppDatabase db, $ChatMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> k = const Value.absent(),
            Value<String> v = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => ChatMetaCompanion(k: k, v: v, rowid: rowid),
          createCompanionCallback: ({
            required String k,
            required String v,
            Value<int> rowid = const Value.absent(),
          }) => ChatMetaCompanion.insert(k: k, v: v, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ChatMetaTable, ChatMetaData>(table),
                  BaseReferences<_$AppDatabase, $ChatMetaTable, ChatMetaData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChatMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ChatMetaTable,
      ChatMetaData,
      $$ChatMetaTableFilterComposer,
      $$ChatMetaTableOrderingComposer,
      $$ChatMetaTableAnnotationComposer,
      $$ChatMetaTableCreateCompanionBuilder,
      $$ChatMetaTableUpdateCompanionBuilder,
      (
        ChatMetaData,
        BaseReferences<_$AppDatabase, $ChatMetaTable, ChatMetaData>,
      ),
      ChatMetaData,
      PrefetchHooks Function()
    >;
typedef $$AttachmentsTableCreateCompanionBuilder =
    AttachmentsCompanion Function({
      required String conversationId,
      required String messageId,
      Value<Uint8List?> data,
      Value<int> rowid,
    });
typedef $$AttachmentsTableUpdateCompanionBuilder =
    AttachmentsCompanion Function({
      Value<String> conversationId,
      Value<String> messageId,
      Value<Uint8List?> data,
      Value<int> rowid,
    });

class $$AttachmentsTableFilterComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AttachmentsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AttachmentsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttachmentsTable> {
  $$AttachmentsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<Uint8List> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);
}

class $$AttachmentsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AttachmentsTable,
          Attachment,
          $$AttachmentsTableFilterComposer,
          $$AttachmentsTableOrderingComposer,
          $$AttachmentsTableAnnotationComposer,
          $$AttachmentsTableCreateCompanionBuilder,
          $$AttachmentsTableUpdateCompanionBuilder,
          (
            Attachment,
            BaseReferences<_$AppDatabase, $AttachmentsTable, Attachment>,
          ),
          Attachment,
          PrefetchHooks Function()
        > {
  $$AttachmentsTableTableManager(_$AppDatabase db, $AttachmentsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttachmentsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AttachmentsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AttachmentsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<Uint8List?> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttachmentsCompanion(
                conversationId: conversationId,
                messageId: messageId,
                data: data,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String messageId,
                Value<Uint8List?> data = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttachmentsCompanion.insert(
                conversationId: conversationId,
                messageId: messageId,
                data: data,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AttachmentsTable, Attachment>(table),
                  BaseReferences<_$AppDatabase, $AttachmentsTable, Attachment>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AttachmentsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AttachmentsTable,
      Attachment,
      $$AttachmentsTableFilterComposer,
      $$AttachmentsTableOrderingComposer,
      $$AttachmentsTableAnnotationComposer,
      $$AttachmentsTableCreateCompanionBuilder,
      $$AttachmentsTableUpdateCompanionBuilder,
      (
        Attachment,
        BaseReferences<_$AppDatabase, $AttachmentsTable, Attachment>,
      ),
      Attachment,
      PrefetchHooks Function()
    >;
typedef $$GroupAnchorsTableCreateCompanionBuilder =
    GroupAnchorsCompanion Function({
      required String conversationId,
      required int n,
      required Uint8List hash,
      Value<int> rowid,
    });
typedef $$GroupAnchorsTableUpdateCompanionBuilder =
    GroupAnchorsCompanion Function({
      Value<String> conversationId,
      Value<int> n,
      Value<Uint8List> hash,
      Value<int> rowid,
    });

class $$GroupAnchorsTableFilterComposer
    extends Composer<_$AppDatabase, $GroupAnchorsTable> {
  $$GroupAnchorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get n => $composableBuilder(
    column: $table.n,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get hash => $composableBuilder(
    column: $table.hash,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GroupAnchorsTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupAnchorsTable> {
  $$GroupAnchorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get n => $composableBuilder(
    column: $table.n,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get hash => $composableBuilder(
    column: $table.hash,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GroupAnchorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupAnchorsTable> {
  $$GroupAnchorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get n =>
      $composableBuilder(column: $table.n, builder: (column) => column);

  GeneratedColumn<Uint8List> get hash =>
      $composableBuilder(column: $table.hash, builder: (column) => column);
}

class $$GroupAnchorsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupAnchorsTable,
          GroupAnchor,
          $$GroupAnchorsTableFilterComposer,
          $$GroupAnchorsTableOrderingComposer,
          $$GroupAnchorsTableAnnotationComposer,
          $$GroupAnchorsTableCreateCompanionBuilder,
          $$GroupAnchorsTableUpdateCompanionBuilder,
          (
            GroupAnchor,
            BaseReferences<_$AppDatabase, $GroupAnchorsTable, GroupAnchor>,
          ),
          GroupAnchor,
          PrefetchHooks Function()
        > {
  $$GroupAnchorsTableTableManager(_$AppDatabase db, $GroupAnchorsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupAnchorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupAnchorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupAnchorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int> n = const Value.absent(),
                Value<Uint8List> hash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupAnchorsCompanion(
                conversationId: conversationId,
                n: n,
                hash: hash,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required int n,
                required Uint8List hash,
                Value<int> rowid = const Value.absent(),
              }) => GroupAnchorsCompanion.insert(
                conversationId: conversationId,
                n: n,
                hash: hash,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GroupAnchorsTable, GroupAnchor>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $GroupAnchorsTable,
                    GroupAnchor
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GroupAnchorsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupAnchorsTable,
      GroupAnchor,
      $$GroupAnchorsTableFilterComposer,
      $$GroupAnchorsTableOrderingComposer,
      $$GroupAnchorsTableAnnotationComposer,
      $$GroupAnchorsTableCreateCompanionBuilder,
      $$GroupAnchorsTableUpdateCompanionBuilder,
      (
        GroupAnchor,
        BaseReferences<_$AppDatabase, $GroupAnchorsTable, GroupAnchor>,
      ),
      GroupAnchor,
      PrefetchHooks Function()
    >;
typedef $$HiddenConversationsTableCreateCompanionBuilder =
    HiddenConversationsCompanion Function({
      required String conversationId,
      required Uint8List pub,
      required String wrapped,
      Value<int> rowid,
    });
typedef $$HiddenConversationsTableUpdateCompanionBuilder =
    HiddenConversationsCompanion Function({
      Value<String> conversationId,
      Value<Uint8List> pub,
      Value<String> wrapped,
      Value<int> rowid,
    });

class $$HiddenConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $HiddenConversationsTable> {
  $$HiddenConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get pub => $composableBuilder(
    column: $table.pub,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wrapped => $composableBuilder(
    column: $table.wrapped,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HiddenConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $HiddenConversationsTable> {
  $$HiddenConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get pub => $composableBuilder(
    column: $table.pub,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wrapped => $composableBuilder(
    column: $table.wrapped,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HiddenConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $HiddenConversationsTable> {
  $$HiddenConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get pub =>
      $composableBuilder(column: $table.pub, builder: (column) => column);

  GeneratedColumn<String> get wrapped =>
      $composableBuilder(column: $table.wrapped, builder: (column) => column);
}

class $$HiddenConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HiddenConversationsTable,
          HiddenConversation,
          $$HiddenConversationsTableFilterComposer,
          $$HiddenConversationsTableOrderingComposer,
          $$HiddenConversationsTableAnnotationComposer,
          $$HiddenConversationsTableCreateCompanionBuilder,
          $$HiddenConversationsTableUpdateCompanionBuilder,
          (
            HiddenConversation,
            BaseReferences<
              _$AppDatabase,
              $HiddenConversationsTable,
              HiddenConversation
            >,
          ),
          HiddenConversation,
          PrefetchHooks Function()
        > {
  $$HiddenConversationsTableTableManager(
    _$AppDatabase db,
    $HiddenConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HiddenConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HiddenConversationsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$HiddenConversationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<Uint8List> pub = const Value.absent(),
                Value<String> wrapped = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HiddenConversationsCompanion(
                conversationId: conversationId,
                pub: pub,
                wrapped: wrapped,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required Uint8List pub,
                required String wrapped,
                Value<int> rowid = const Value.absent(),
              }) => HiddenConversationsCompanion.insert(
                conversationId: conversationId,
                pub: pub,
                wrapped: wrapped,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HiddenConversationsTable, HiddenConversation>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $HiddenConversationsTable,
                    HiddenConversation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HiddenConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HiddenConversationsTable,
      HiddenConversation,
      $$HiddenConversationsTableFilterComposer,
      $$HiddenConversationsTableOrderingComposer,
      $$HiddenConversationsTableAnnotationComposer,
      $$HiddenConversationsTableCreateCompanionBuilder,
      $$HiddenConversationsTableUpdateCompanionBuilder,
      (
        HiddenConversation,
        BaseReferences<
          _$AppDatabase,
          $HiddenConversationsTable,
          HiddenConversation
        >,
      ),
      HiddenConversation,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalProfilesTableTableManager get localProfiles =>
      $$LocalProfilesTableTableManager(_db, _db.localProfiles);
  $$DirUsersTableTableManager get dirUsers =>
      $$DirUsersTableTableManager(_db, _db.dirUsers);
  $$KnownDevicesTableTableManager get knownDevices =>
      $$KnownDevicesTableTableManager(_db, _db.knownDevices);
  $$SeenKeysTableTableManager get seenKeys =>
      $$SeenKeysTableTableManager(_db, _db.seenKeys);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$EpochKeysTableTableManager get epochKeys =>
      $$EpochKeysTableTableManager(_db, _db.epochKeys);
  $$ChatMessagesTableTableManager get chatMessages =>
      $$ChatMessagesTableTableManager(_db, _db.chatMessages);
  $$ChatMetaTableTableManager get chatMeta =>
      $$ChatMetaTableTableManager(_db, _db.chatMeta);
  $$AttachmentsTableTableManager get attachments =>
      $$AttachmentsTableTableManager(_db, _db.attachments);
  $$GroupAnchorsTableTableManager get groupAnchors =>
      $$GroupAnchorsTableTableManager(_db, _db.groupAnchors);
  $$HiddenConversationsTableTableManager get hiddenConversations =>
      $$HiddenConversationsTableTableManager(_db, _db.hiddenConversations);
}

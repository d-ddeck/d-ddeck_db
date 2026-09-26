import 'common.dart';

class CodeItemUsage {
  const CodeItemUsage({
    required this.count,
    required this.by,
    required this.children,
    this.isProtected = false,
    this.protectedReason,
  });

  final int count;
  final Map<String, int> by;
  final int children;
  final bool isProtected;
  final String? protectedReason;

  factory CodeItemUsage.fromJson(Map<String, dynamic> j) => CodeItemUsage(
    count: asInt(j['count']),
    by: asMap(j['by']).map((key, value) => MapEntry(key, asInt(value))),
    children: asInt(j['children']),
    isProtected: asBool(j['is_protected']),
    protectedReason: j['protected_reason'] as String?,
  );
}

/// The six settings namespaces the server exposes at /admin/settings/{module}.
enum SettingsModule {
  system('SYSTEM', '시스템'),
  auth('AUTH', '계정 / 인증'),
  service('SERVICE', '서비스(AS)'),
  inventory('INVENTORY', '재고관리'),
  board('BOARD', '게시판'),
  calendar('CALENDAR', '캘린더');

  const SettingsModule(this.value, this.label);
  final String value;
  final String label;
}

/// One row of a settings screen.
///
/// `valueType` is what the UI switches on to pick a widget, so a new setting
/// added on the server appears here with no client change.
class ModuleSetting {
  ModuleSetting({
    required this.key,
    required this.valueType,
    required this.value,
    this.label,
    this.description,
    this.isPublic = false,
  });

  final String key;
  final String valueType; // string | int | float | bool | list | json
  final String? label;
  final String? description;
  final bool isPublic;
  dynamic value;

  String get displayLabel => label?.isNotEmpty == true ? label! : key;

  bool get asBoolean => asBool(value);
  int get asInteger => asInt(value);
  String get asText => value == null ? '' : value.toString();
  List<String> get asStringList =>
      value is List ? (value as List).map((e) => e.toString()).toList() : [];

  /// Coerces editor input back into the declared type before sending.
  void setFromInput(dynamic input) {
    value = switch (valueType) {
      'int' => input is int ? input : int.tryParse(input.toString()) ?? 0,
      'float' =>
        input is num
            ? input.toDouble()
            : double.tryParse(input.toString()) ?? 0,
      'bool' => asBool(input),
      'list' => input is List ? input : [input.toString()],
      _ => input,
    };
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'value': value,
    'value_type': valueType,
    'label': label,
    'description': description,
    'is_public': isPublic,
  };

  factory ModuleSetting.fromJson(Map<String, dynamic> j) => ModuleSetting(
    key: asString(j['key']),
    valueType: asString(j['value_type'], 'string'),
    value: j['value'],
    label: j['label'] as String?,
    description: j['description'] as String?,
    isPublic: asBool(j['is_public']),
  );
}

/// Everything one settings screen renders, in a single response.
class ModuleSettings {
  const ModuleSettings({
    required this.module,
    required this.settings,
    required this.codeGroups,
  });

  final String module;
  final List<ModuleSetting> settings;
  final List<CodeGroup> codeGroups;

  factory ModuleSettings.fromJson(Map<String, dynamic> j) => ModuleSettings(
    module: asString(j['module']),
    settings: asList(j['settings'], ModuleSetting.fromJson),
    codeGroups: asList(j['code_groups'], CodeGroup.fromJson),
  );

  static ModuleSettings empty(String module) =>
      ModuleSettings(module: module, settings: const [], codeGroups: const []);
}

class AuditLog {
  const AuditLog({
    required this.id,
    required this.action,
    this.actorEmail,
    this.module,
    this.entityType,
    this.summary,
    this.ipAddress,
    this.createdAt,
  });

  final String id;
  final String action;
  final String? actorEmail;
  final String? module;
  final String? entityType;
  final String? summary;
  final String? ipAddress;
  final DateTime? createdAt;

  static const actionLabels = {
    'CREATE': '생성',
    'UPDATE': '수정',
    'DELETE': '삭제',
    'LOGIN': '로그인',
    'LOGIN_FAILED': '로그인 실패',
    'LOGOUT': '로그아웃',
    'APPROVE': '승인',
    'REJECT': '반려',
    'SETTING_CHANGE': '설정 변경',
  };

  String get actionLabel => actionLabels[action] ?? action;

  factory AuditLog.fromJson(Map<String, dynamic> j) => AuditLog(
    id: asString(j['id']),
    action: asString(j['action']),
    actorEmail: j['actor_email'] as String?,
    module: j['module'] as String?,
    entityType: j['entity_type'] as String?,
    summary: j['summary'] as String?,
    ipAddress: j['ip_address'] as String?,
    createdAt: asDate(j['created_at']),
  );
}

class ServerHealth {
  const ServerHealth({
    required this.status,
    required this.version,
    required this.environment,
    required this.database,
    required this.databaseOk,
    required this.uptimeSeconds,
    this.serverTime,
    this.backup = const {},
    this.diskFreeBytes = 0,
    this.schemaRevisions = const [],
  });

  final String status;
  final String version;
  final String environment;
  final String database;
  final bool databaseOk;
  final double uptimeSeconds;
  final DateTime? serverTime;
  final Map<String, dynamic> backup;
  final int diskFreeBytes;
  final List<String> schemaRevisions;

  String get uptimeLabel {
    final d = Duration(seconds: uptimeSeconds.round());
    if (d.inDays > 0) return '${d.inDays}일 ${d.inHours % 24}시간';
    if (d.inHours > 0) return '${d.inHours}시간 ${d.inMinutes % 60}분';
    if (d.inMinutes > 0) return '${d.inMinutes}분';
    return '${d.inSeconds}초';
  }

  factory ServerHealth.fromJson(Map<String, dynamic> j) => ServerHealth(
    status: asString(j['status']),
    version: asString(j['version']),
    environment: asString(j['environment']),
    database: asString(j['database']),
    databaseOk: asBool(j['database_ok']),
    uptimeSeconds: asDouble(j['uptime_seconds']) ?? 0,
    serverTime: asDate(j['server_time']),
    backup: asMap(j['backup']),
    diskFreeBytes: asInt(j['disk_free_bytes']),
    schemaRevisions: (j['schema_revisions'] as List? ?? [])
        .map((e) => '$e')
        .toList(),
  );
}

class SystemStats {
  const SystemStats({
    required this.usersTotal,
    required this.usersPending,
    required this.usersActive,
    required this.ticketsTotal,
    required this.ticketsOpen,
    required this.assetsTotal,
    required this.postsTotal,
    required this.eventsUpcoming,
    required this.storageBytes,
    required this.tables,
  });

  final int usersTotal;
  final int usersPending;
  final int usersActive;
  final int ticketsTotal;
  final int ticketsOpen;
  final int assetsTotal;
  final int postsTotal;
  final int eventsUpcoming;
  final int storageBytes;
  final List<({String table, int rows})> tables;

  String get storageLabel {
    if (storageBytes < 1024) return '$storageBytes B';
    if (storageBytes < 1024 * 1024) {
      return '${(storageBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(storageBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  factory SystemStats.fromJson(Map<String, dynamic> j) => SystemStats(
    usersTotal: asInt(j['users_total']),
    usersPending: asInt(j['users_pending']),
    usersActive: asInt(j['users_active']),
    ticketsTotal: asInt(j['tickets_total']),
    ticketsOpen: asInt(j['tickets_open']),
    assetsTotal: asInt(j['assets_total']),
    postsTotal: asInt(j['posts_total']),
    eventsUpcoming: asInt(j['events_upcoming']),
    storageBytes: asInt(j['storage_bytes']),
    tables: (j['tables'] as List? ?? [])
        .map(
          (e) => (
            table: asString(asMap(e)['table']),
            rows: asInt(asMap(e)['rows']),
          ),
        )
        .toList(),
  );
}

/// Shared shapes and JSON helpers.
///
/// Hand-written parsers rather than codegen: the vendor extending this
/// skeleton should be able to add a field without running build_runner.
library;

/// Every paginated list endpoint returns this envelope.
///
/// Named PagedList rather than Page because Flutter's Navigator already
/// exports a `Page` class, and the collision is silent until it is not.
class PagedList<T> {
  const PagedList({
    required this.items,
    required this.total,
    required this.page,
    required this.size,
    required this.pages,
  });

  final List<T> items;
  final int total;
  final int page;
  final int size;
  final int pages;

  bool get hasMore => page < pages;
  bool get isEmpty => items.isEmpty;

  static PagedList<T> fromJson<T>(
    dynamic json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) {
    // A few endpoints return a bare array instead of the envelope. Accept both
    // so callers do not have to know which is which.
    if (json is List) {
      final items = json.map((e) => itemFromJson(asMap(e))).toList();
      return PagedList(
        items: items,
        total: items.length,
        page: 1,
        size: items.length,
        pages: 1,
      );
    }
    final map = asMap(json);
    return PagedList(
      items: (map['items'] as List? ?? [])
          .map((e) => itemFromJson(asMap(e)))
          .toList(),
      total: asInt(map['total']),
      page: asInt(map['page'], 1),
      size: asInt(map['size'], 20),
      pages: asInt(map['pages'], 1),
    );
  }

  static PagedList<T> empty<T>() =>
      PagedList(items: const [], total: 0, page: 1, size: 20, pages: 0);
}

/// A classification entry from the code master (서비스 분류, 자산 분류 …).
class CodeItem {
  const CodeItem({
    required this.id,
    required this.code,
    required this.name,
    this.color,
    this.sortOrder = 0,
    this.isActive = true,
    this.groupId,
    this.parentId,
  });

  final String id;
  final String code;
  final String name;
  final String? color;
  final int sortOrder;
  final bool isActive;
  final String? groupId;
  final String? parentId;

  factory CodeItem.fromJson(Map<String, dynamic> j) => CodeItem(
        id: asString(j['id']),
        code: asString(j['code']),
        name: asString(j['name']),
        color: j['color'] as String?,
        sortOrder: asInt(j['sort_order']),
        isActive: asBool(j['is_active'], true),
        groupId: j['group_id'] as String?,
        parentId: j['parent_id'] as String?,
      );
}

class CodeGroup {
  const CodeGroup({
    required this.id,
    required this.code,
    required this.name,
    required this.module,
    required this.items,
    this.isSystem = false,
  });

  final String id;
  final String code;
  final String name;
  final String module;
  final List<CodeItem> items;
  final bool isSystem;

  /// Only the entries that may be offered as a new choice.
  List<CodeItem> get selectable => items.where((i) => i.isActive).toList();

  factory CodeGroup.fromJson(Map<String, dynamic> j) => CodeGroup(
        id: asString(j['id']),
        code: asString(j['code']),
        name: asString(j['name']),
        module: asString(j['module']),
        isSystem: asBool(j['is_system']),
        items: (j['items'] as List? ?? [])
            .map((e) => CodeItem.fromJson(asMap(e)))
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      );
}

/// The embedded person shape used for authors, assignees and participants.
class UserBrief {
  const UserBrief({required this.id, required this.fullName, this.position});

  final String id;
  final String fullName;
  final String? position;

  String get display =>
      position == null || position!.isEmpty ? fullName : '$fullName $position';

  factory UserBrief.fromJson(Map<String, dynamic> j) => UserBrief(
        id: asString(j['id']),
        fullName: asString(j['full_name']),
        position: j['position'] as String?,
      );
}

/// One row of any grouped statistic.
///
/// `label` and `color` come from the server so the client never keeps its own
/// Korean label table or chart palette - changing a code's colour in the admin
/// settings updates the charts here automatically.
class StatBucket {
  const StatBucket({
    required this.key,
    required this.label,
    required this.count,
    required this.ratio,
    this.ticketCount,
    this.color,
    this.avgResolutionMinutes,
    this.totalCost,
  });

  final String key;
  final String label;
  final int count;
  // 한 대응에 여러 분류가 붙으므로 원인 수와 중복을 뺀 대응 건수는 다를 수 있다.
  final int? ticketCount;
  final double ratio;
  final String? color;
  final double? avgResolutionMinutes;
  final double? totalCost;

  factory StatBucket.fromJson(Map<String, dynamic> j) => StatBucket(
        key: asString(j['key']),
        label: asString(j['label']),
        count: asInt(j['count']),
        ticketCount: j['ticket_count'] == null ? null : asInt(j['ticket_count']),
        ratio: asDouble(j['ratio']) ?? 0,
        color: j['color'] as String?,
        avgResolutionMinutes: asDouble(j['avg_resolution_minutes']),
        totalCost: asDouble(j['total_cost']),
      );
}

// ------------------------------------------------------------------ helpers

Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

String asString(dynamic v, [String fallback = '']) => v?.toString() ?? fallback;

int asInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool asBool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is String) return v.toLowerCase() == 'true';
  if (v is num) return v != 0;
  return fallback;
}

/// Money and quantity arrive as JSON strings ("150000.00"), because the server
/// uses Decimal. Parsing them as num would silently fail.
double? asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// All timestamps are UTC ISO-8601; convert to local for display.
DateTime? asDate(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s)?.toLocal();
}

List<T> asList<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    (v as List? ?? []).map((e) => f(asMap(e))).toList();

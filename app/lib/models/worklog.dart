import 'common.dart';

/// 정규 근무 09:00~18:00. 18:00 이후 근무만 연장이다(09:00 이전은 넣지 않는다).
/// 종료가 시작보다 이르면 자정을 넘긴 것으로 본다. 서버와 같은 규칙.
int overtimeMinutes(String start, String end) {
  int minutes(String v) {
    final parts = v.split(':');
    if (parts.length != 2) return -1;
    final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
    return h == null || m == null ? -1 : h * 60 + m;
  }

  final s = minutes(start);
  var e = minutes(end);
  if (s < 0 || e < 0) return 0;
  if (e <= s) e += 24 * 60;
  final from = s > 18 * 60 ? s : 18 * 60;
  return e > from ? e - from : 0;
}

/// 150 -> "2시간 30분"
String overtimeLabel(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  return [if (h > 0) '$h시간', if (m > 0 || h == 0) '$m분'].join(' ');
}

class WorkLog {
  WorkLog.fromJson(Map<String, dynamic> j)
    : id = asString(j['id']),
      authorId = asString(j['author_id']),
      authorName = asString(j['author_name']),
      position = asString(j['position']),
      workDate = asString(j['work_date']),
      workStart = asString(j['work_start']),
      workEnd = asString(j['work_end']),
      morning = asString(j['morning']),
      afternoon = asString(j['afternoon']),
      summary = asString(j['summary']),
      detail = asString(j['detail']),
      overtime = asBool(j['overtime']),
      overtimeMinutes = asInt(j['overtime_minutes']),
      overtimeNote = asString(j['overtime_note']),
      plan = asString(j['plan']),
      needs = asString(j['needs']),
      visibility = asString(j['visibility'], 'PRIVATE'),
      attachmentCount = asInt(j['attachment_count']),
      canEdit = asBool(j['can_edit']),
      createdAt = asDate(j['created_at']),
      updatedAt = asDate(j['updated_at']),
      author = j['author'] is Map
          ? UserBrief.fromJson(asMap(j['author']))
          : null,
      createdBy = j['created_by'] is Map
          ? UserBrief.fromJson(asMap(j['created_by']))
          : null,
      updatedBy = j['updated_by'] is Map
          ? UserBrief.fromJson(asMap(j['updated_by']))
          : null;

  final String id, authorId, authorName, position, workDate, workStart, workEnd;
  final String morning, afternoon;
  final String summary, detail, overtimeNote, plan, needs, visibility;
  final bool overtime, canEdit;
  final int attachmentCount, overtimeMinutes;
  final DateTime? createdAt, updatedAt;
  final UserBrief? author, createdBy, updatedBy;

  Map<String, dynamic> toForm() => {
    'work_date': workDate,
    'work_start': workStart,
    'work_end': workEnd,
    'position': position,
    'morning': morning,
    'afternoon': afternoon,
    'summary': summary,
    'detail': detail,
    'overtime': overtime,
    'overtime_note': overtimeNote,
    'plan': plan,
    'needs': needs,
    'visibility': visibility,
  };
}

class WorkLogDraft {
  WorkLogDraft.fromJson(Map<String, dynamic> j)
    : data = asMap(j['data']),
      savedAt = asDate(j['saved_at']);
  final Map<String, dynamic> data;
  final DateTime? savedAt;
}

class WorkLogLookups {
  WorkLogLookups.fromJson(Map<String, dynamic> j)
    : positions = (j['positions'] as List? ?? [])
          .map((v) => asString(v))
          .toList(),
      fixedPosition = asString(j['fixed_position']),
      authorName = asString(j['author_name']),
      defaultWorkStart = asString(j['default_work_start'], '09:00'),
      defaultWorkEnd = asString(j['default_work_end'], '18:00'),
      authors = asList(j['authors'], UserBrief.fromJson),
      years = (j['years'] as List? ?? []).map((v) => asInt(v)).toList(),
      draft = j['draft'] is Map
          ? WorkLogDraft.fromJson(asMap(j['draft']))
          : null;
  final List<String> positions;
  final String fixedPosition, authorName, defaultWorkStart, defaultWorkEnd;
  final List<UserBrief> authors;
  final List<int> years;
  final WorkLogDraft? draft;
  int get autosaveSeconds => 5;
}

class OvertimeDay {
  OvertimeDay.fromJson(Map<String, dynamic> j)
    : id = asString(j['id']),
      workDate = asString(j['work_date']),
      workStart = asString(j['work_start']),
      workEnd = asString(j['work_end']),
      minutes = asInt(j['minutes']),
      reason = asString(j['reason']);
  final String id, workDate, workStart, workEnd, reason;
  final int minutes;
}

class OvertimeSummary {
  OvertimeSummary.fromJson(Map<String, dynamic> j)
    : items = (j['items'] as List? ?? [])
          .map((e) => OvertimeDay.fromJson(asMap(e)))
          .toList(),
      totalMinutes = asInt(j['total_minutes']);
  final List<OvertimeDay> items;
  final int totalMinutes;
}

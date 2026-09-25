import 'common.dart';

class WorkLog {
  WorkLog.fromJson(Map<String, dynamic> j)
      : id = asString(j['id']), authorId = asString(j['author_id']),
        authorName = asString(j['author_name']), position = asString(j['position']),
        workDate = asString(j['work_date']), workStart = asString(j['work_start']),
        workEnd = asString(j['work_end']), summary = asString(j['summary']),
        detail = asString(j['detail']), overtime = asBool(j['overtime']),
        overtimeNote = asString(j['overtime_note']), plan = asString(j['plan']),
        needs = asString(j['needs']), visibility = asString(j['visibility'], 'PRIVATE'),
        attachmentCount = asInt(j['attachment_count']), canEdit = asBool(j['can_edit']),
        createdAt = asDate(j['created_at']), updatedAt = asDate(j['updated_at']),
        author = j['author'] is Map ? UserBrief.fromJson(asMap(j['author'])) : null,
        createdBy = j['created_by'] is Map ? UserBrief.fromJson(asMap(j['created_by'])) : null,
        updatedBy = j['updated_by'] is Map ? UserBrief.fromJson(asMap(j['updated_by'])) : null;

  final String id, authorId, authorName, position, workDate, workStart, workEnd;
  final String summary, detail, overtimeNote, plan, needs, visibility;
  final bool overtime, canEdit;
  final int attachmentCount;
  final DateTime? createdAt, updatedAt;
  final UserBrief? author, createdBy, updatedBy;

  Map<String, dynamic> toForm() => {
    'work_date': workDate, 'work_start': workStart, 'work_end': workEnd,
    'position': position, 'summary': summary, 'detail': detail,
    'overtime': overtime, 'overtime_note': overtimeNote, 'plan': plan,
    'needs': needs, 'visibility': visibility,
  };
}

class WorkLogDraft {
  WorkLogDraft.fromJson(Map<String, dynamic> j)
      : data = asMap(j['data']), savedAt = asDate(j['saved_at']);
  final Map<String, dynamic> data;
  final DateTime? savedAt;
}

class WorkLogLookups {
  WorkLogLookups.fromJson(Map<String, dynamic> j)
      : positions = (j['positions'] as List? ?? []).map((v) => asString(v)).toList(),
        fixedPosition = asString(j['fixed_position']), authorName = asString(j['author_name']),
        defaultWorkStart = asString(j['default_work_start'], '09:00'),
        defaultWorkEnd = asString(j['default_work_end'], '18:00'),
        authors = asList(j['authors'], UserBrief.fromJson),
        years = (j['years'] as List? ?? []).map((v) => asInt(v)).toList(),
        draft = j['draft'] is Map ? WorkLogDraft.fromJson(asMap(j['draft'])) : null;
  final List<String> positions;
  final String fixedPosition, authorName, defaultWorkStart, defaultWorkEnd;
  final List<UserBrief> authors;
  final List<int> years;
  final WorkLogDraft? draft;
  int get autosaveSeconds => 5;
}

import 'common.dart';

/// Mirrors the server's Role ladder. The int is what permission checks compare;
/// keep it in sync with ROLE_LEVEL in app/models/enums.py.
enum Role {
  member('MEMBER', '사원', 1),
  manager('MANAGER', '팀장', 2),
  admin('ADMIN', '관리자', 3),
  superadmin('SUPERADMIN', '최고관리자', 4);

  const Role(this.value, this.label, this.level);
  final String value;
  final String label;
  final int level;

  static Role parse(String? v) =>
      Role.values.firstWhere((r) => r.value == v, orElse: () => Role.member);

  bool atLeast(Role other) => level >= other.level;
}

enum UserStatus {
  unknown('UNKNOWN', '알 수 없는 상태'),
  pending('PENDING', '승인 대기'),
  approved('APPROVED', '사용중'),
  rejected('REJECTED', '반려'),
  suspended('SUSPENDED', '정지'),
  resigned('RESIGNED', '퇴사');

  const UserStatus(this.value, this.label);
  final String value;
  final String label;

  static UserStatus parse(String? v) => UserStatus.values.firstWhere(
    (s) => s.value == v,
    orElse: () => UserStatus.unknown,
  );
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.status,
    this.employeeNo,
    this.phone,
    this.position,
    this.departmentId,
    this.departmentName,
    this.mustChangePassword = false,
    this.lastLoginAt,
    this.createdAt,
    // admin-only fields; null for a self profile
    this.approvedAt,
    this.rejectionReason,
    this.signupNote,
  });

  final String id;
  final String email;
  final String fullName;
  final Role role;
  final UserStatus status;
  final String? employeeNo;
  final String? phone;
  final String? position;
  final String? departmentId;
  final String? departmentName;
  final bool mustChangePassword;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;
  final DateTime? approvedAt;
  final String? rejectionReason;
  final String? signupNote;

  String get display =>
      position == null || position!.isEmpty ? fullName : '$fullName $position';

  factory UserProfile.fromJson(Map<String, dynamic> j) {
    final dept = j['department'];
    return UserProfile(
      id: asString(j['id']),
      email: asString(j['email']),
      fullName: asString(j['full_name']),
      role: Role.parse(j['role'] as String?),
      status: UserStatus.parse(j['status'] as String?),
      employeeNo: j['employee_no'] as String?,
      phone: j['phone'] as String?,
      position: j['position'] as String?,
      departmentId: j['department_id'] as String?,
      departmentName:
          j['department_name'] as String? ??
          (dept is Map ? dept['name'] as String? : null),
      mustChangePassword: asBool(j['must_change_password']),
      lastLoginAt: asDate(j['last_login_at']),
      createdAt: asDate(j['created_at']),
      approvedAt: asDate(j['approved_at']),
      rejectionReason: j['rejection_reason'] as String?,
      signupNote: j['signup_note'] as String?,
    );
  }
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final UserProfile user;
  final DateTime? expiresAt;

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
    accessToken: asString(j['access_token']),
    refreshToken: asString(j['refresh_token']),
    expiresAt: asDate(j['expires_at']),
    user: UserProfile.fromJson(asMap(j['user'])),
  );
}

class Department {
  const Department({
    required this.id,
    required this.name,
    this.code,
    this.parentId,
    this.userCount = 0,
  });

  final String id;
  final String name;
  final String? code;
  final String? parentId;
  final int userCount;

  factory Department.fromJson(Map<String, dynamic> j) => Department(
    id: asString(j['id']),
    name: asString(j['name']),
    code: j['code'] as String?,
    parentId: j['parent_id'] as String?,
    userCount: asInt(j['user_count']),
  );
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.isRead,
    this.body,
    this.payload,
    this.createdAt,
  });

  final String id;
  final String type;
  final String title;
  final bool isRead;
  final String? body;
  final Map<String, dynamic>? payload;
  final DateTime? createdAt;

  /// Deep-link target the server put in `payload.route`.
  String? get route => payload?['route'] as String?;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: asString(j['id']),
    type: asString(j['type']),
    title: asString(j['title']),
    body: j['body'] as String?,
    isRead: asBool(j['is_read']),
    payload: j['payload'] is Map ? asMap(j['payload']) : null,
    createdAt: asDate(j['created_at']),
  );
}

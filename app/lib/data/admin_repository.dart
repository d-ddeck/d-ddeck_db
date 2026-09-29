import '../core/api_client.dart';
import '../models/admin.dart';
import '../models/common.dart';

class AdminRepository {
  AdminRepository(this._api);
  final ApiClient _api;

  Future<Map<String, dynamic>> driveBackup() async =>
      asMap(await _api.get('/admin/drive-backup'));
  Future<void> configureDriveBackup(Map<String, dynamic> values) async {
    await _api.put('/admin/drive-backup/config', body: values);
  }

  Future<Map<String, dynamic>> driveBackupFiles() async =>
      asMap(await _api.get('/admin/drive-backup/files'));
  Future<String> startBackupRestore(String name, bool restore) async =>
      asMap(
            await _api.post(
              '/admin/drive-backup/restore/start',
              body: {
                'name': name,
                'restore': restore,
                'confirmation': restore ? name : '',
              },
            ),
          )['ticket']
          as String;
  Future<Map<String, dynamic>> backupRestoreStatus(String ticket) async =>
      asMap(
        await _api.post(
          '/admin/drive-backup/restore/status',
          body: {'ticket': ticket},
          skipAuth: true,
        ),
      );
  Future<void> downloadBackup(String ticket, String destination) =>
      _api.downloadBackup(ticket, destination);

  Future<Map<String, dynamic>> startDriveSetup() async =>
      asMap(await _api.post('/admin/drive-backup/setup'));
  Future<Map<String, dynamic>> driveSetup(String id) async =>
      asMap(await _api.get('/admin/drive-backup/setup/$id'));
  Future<Map<String, dynamic>> answerDriveSetup(
    String id,
    String value,
  ) async => asMap(
    await _api.post(
      '/admin/drive-backup/setup/$id/answer',
      body: {'value': value},
    ),
  );
  Future<void> cancelDriveSetup(String id) async {
    await _api.delete('/admin/drive-backup/setup/$id');
  }

  Future<List<String>> driveSetupFolders(String id, String parent) async {
    final data = asMap(
      await _api.get(
        '/admin/drive-backup/setup/$id/folders',
        query: {'parent': parent},
      ),
    );
    return (data['folders'] as List).cast<String>();
  }

  Future<void> finishDriveSetup(String id, String folder, bool create) async {
    await _api.post(
      '/admin/drive-backup/setup/$id/finish',
      body: {'folder': folder, 'create': create},
    );
  }

  Future<void> configureRcloneDrive(String target) async {
    await _api.put('/admin/drive-backup/rclone', body: {'target': target});
  }

  Future<void> configureSharedDrive(String keyJson, String folder) async {
    await _api.put(
      '/admin/drive-backup/shared-drive',
      body: {'service_account_json': keyJson, 'folder': folder},
    );
  }

  Future<String> connectDriveBackup() async =>
      asString(asMap(await _api.post('/admin/drive-backup/connect'))['url']);
  Future<void> disconnectDriveBackup() async {
    await _api.delete('/admin/drive-backup/connection');
  }

  Future<void> scheduleDriveBackup(bool enabled, int hour) async {
    await _api.put(
      '/admin/drive-backup/schedule',
      body: {'enabled': enabled, 'hour': hour},
    );
  }

  Future<void> runDriveBackup() async {
    await _api.post('/admin/drive-backup/run');
  }

  /// Everything one settings screen needs: the key/value rows plus the
  /// classification lists that belong to the same module.
  Future<ModuleSettings> settings(SettingsModule module) async =>
      ModuleSettings.fromJson(
        asMap(await _api.get('/admin/settings/${module.value}')),
      );

  /// Saves the whole form at once. The server upserts by key.
  Future<ModuleSettings> saveSettings(
    SettingsModule module,
    List<ModuleSetting> settings,
  ) async {
    final res = await _api.put(
      '/admin/settings/${module.value}',
      body: {'settings': settings.map((s) => s.toJson()).toList()},
    );
    return ModuleSettings.fromJson(asMap(res));
  }

  /// Classification master. Used by every form with a category dropdown, so
  /// the client never hardcodes the choices.
  Future<CodeGroup> codeGroup(String groupCode) async =>
      CodeGroup.fromJson(asMap(await _api.get('/admin/codes/$groupCode')));

  Future<List<CodeGroup>> codeGroups({String? module}) async {
    final res = await _api.get('/admin/codes', query: {'module': module});
    return (res as List? ?? [])
        .map((e) => CodeGroup.fromJson(asMap(e)))
        .toList();
  }

  Future<CodeItem> addCodeItem(
    String groupId, {
    required String code,
    required String name,
    String? color,
    String? parentId,
    int sortOrder = 0,
  }) async {
    final res = await _api.post(
      '/admin/codes/$groupId/items',
      body: {
        'code': code,
        'name': name,
        if (color != null) 'color': color,
        if (parentId != null) 'parent_id': parentId,
        'sort_order': sortOrder,
      },
    );
    return CodeItem.fromJson(asMap(res));
  }

  Future<CodeItem> updateCodeItem(
    String itemId,
    Map<String, dynamic> changes,
  ) async {
    final res = await _api.patch('/admin/codes/items/$itemId', body: changes);
    return CodeItem.fromJson(asMap(res));
  }

  Future<CodeItemUsage> codeItemUsage(String itemId) async =>
      CodeItemUsage.fromJson(
        asMap(await _api.get('/admin/codes/items/$itemId/usage')),
      );

  /// Removes the item from lists while preserving names in existing records.
  Future<String> deleteCodeItem(String itemId) async {
    final res = await _api.delete('/admin/codes/items/$itemId');
    return asString(asMap(res)['message']);
  }

  Future<void> reorderCodeItems(String groupId, List<String> itemIds) =>
      _api.post('/admin/codes/$groupId/reorder', body: {'item_ids': itemIds});

  Future<ServerHealth> health() async =>
      ServerHealth.fromJson(asMap(await _api.get('/admin/health')));

  Future<void> requestBackup() async {
    await _api.post('/admin/backup');
  }

  Future<SystemStats> stats() async =>
      SystemStats.fromJson(asMap(await _api.get('/admin/stats')));

  Future<List<AuditLog>> auditLogs({
    int page = 1,
    int size = 50,
    String? action,
    String? module,
    String? query,
  }) async {
    final res = await _api.get(
      '/admin/audit-logs',
      query: {
        'page': page,
        'size': size,
        'action': action,
        'module': module,
        'q': query,
      },
    );
    return (res as List? ?? [])
        .map((e) => AuditLog.fromJson(asMap(e)))
        .toList();
  }
}

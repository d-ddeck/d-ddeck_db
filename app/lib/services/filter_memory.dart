import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences are isolated by server and account; never store login credentials.
class FilterMemory {
  static String key(String server, String user, String module) =>
      'filters.v1.${Uri.encodeComponent(server)}.$user.$module';
  static Future<Map<String, dynamic>> load(String key) async {
    try {
      final value = (await SharedPreferences.getInstance()).getString(key);
      return value == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(value) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String key, Map<String, dynamic> filters) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode(filters),
      );
    } catch (_) {
      /* Filtering still works when preferences are unavailable. */
    }
  }
}

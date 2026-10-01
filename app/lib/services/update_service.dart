import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/company_tls.dart';
import '../core/version.dart';

class ClientUpdate {
  ClientUpdate(
    this.version,
    this.build,
    this.release,
    this.filename,
    this.size,
    this.sha256,
    this.serverUrl,
  );
  final String version, release, filename, sha256, serverUrl;
  final int build, size;

  static List<int> versionParts(String version) {
    if (!RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(version)) {
      throw const FormatException('Invalid version');
    }
    return version.split(RegExp(r'[.+]')).map(int.parse).toList();
  }

  bool isNewerThan(String current) {
    final candidate = versionParts('$version+$build');
    final installed = versionParts(current);
    for (var i = 0; i < 4; i++) {
      if (candidate[i] != installed[i]) return candidate[i] > installed[i];
    }
    return false;
  }

  static Future<ClientUpdate> verified(
    Map<String, dynamic> envelope,
    String publicKey,
    String platform,
    String serverUrl,
  ) async {
    final bytes = base64Decode(envelope['payload'] as String);
    final valid = await Ed25519().verify(
      bytes,
      signature: Signature(
        base64Decode(envelope['signature'] as String),
        publicKey: SimplePublicKey(
          base64Decode(publicKey.trim()),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) throw const FormatException('업데이트 서명을 확인할 수 없습니다.');
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final version = data['version'] as String;
    final build = data['build'] as int;
    versionParts('$version+$build');
    if (data['schema'] != 1 ||
        build < 1 ||
        data['release'] != '$version-$build') {
      throw const FormatException('업데이트 정보가 올바르지 않습니다.');
    }
    final artifact = (data['artifacts'] as Map)[platform] as Map;
    final expected = platform == 'windows'
        ? 'ddeck-setup-$version.exe'
        : 'ddeck-$version-arm64.apk';
    final size = artifact['size'] as int;
    final digest = artifact['sha256'] as String;
    if (artifact['filename'] != expected ||
        size <= 0 ||
        size > 1024 * 1024 * 1024 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('업데이트 파일 정보가 올바르지 않습니다.');
    }
    return ClientUpdate(
      version,
      build,
      data['release'] as String,
      expected,
      size,
      digest,
      serverUrl,
    );
  }
}

class UpdateService {
  UpdateService({Dio? dio, Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: false,
            ),
          ) {
    if (dio == null) _dio.httpClientAdapter = CompanyTls.adapter();
  }
  final Dio _dio;
  final Future<Directory> Function() _directory;
  static const _channel = MethodChannel('ddeck/updates');
  static bool get supported => Platform.isWindows || Platform.isAndroid;

  Future<ClientUpdate?> check(String serverUrl) async {
    if (!supported) return null;
    try {
      final response = await _dio.get<ResponseBody>(
        '$serverUrl${AppConfig.apiPrefix}/updates/latest',
        options: Options(responseType: ResponseType.stream),
      );
      final bytes = <int>[];
      await for (final chunk in response.data!.stream) {
        if (bytes.length + chunk.length > 65536) {
          throw const FormatException('업데이트 정보가 너무 큽니다.');
        }
        bytes.addAll(chunk);
      }
      final body = utf8.decode(bytes);
      final update = await ClientUpdate.verified(
        jsonDecode(body) as Map<String, dynamic>,
        await rootBundle.loadString('assets/update_public_key.txt'),
        Platform.isWindows ? 'windows' : 'android',
        serverUrl,
      );
      return update.isNewerThan(appVersion) ? update : null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> verifyFile(File file, ClientUpdate update) async {
    if (await file.length() != update.size ||
        (await hashes.sha256.bind(file.openRead()).first).toString() !=
            update.sha256) {
      throw const FormatException('다운로드 파일 검증에 실패했습니다. 다시 다운로드해 주세요.');
    }
  }

  Future<File> download(
    ClientUpdate update,
    CancelToken cancel,
    void Function(double) progress,
  ) async {
    final support = await _directory();
    final directory = Directory('${support.path}/updates');
    await directory.create(recursive: true);
    final file = File('${directory.path}/${update.filename}');
    if (await file.exists()) {
      try {
        await verifyFile(file, update);
        return file;
      } catch (_) {
        await file.delete();
      }
    }
    final partial = File('${file.path}.part');
    IOSink? sink;
    try {
      final response = await _dio.get<ResponseBody>(
        '${update.serverUrl}${AppConfig.apiPrefix}/updates/files/${update.release}/${update.filename}',
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancel,
      );
      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in response.data!.stream) {
        if (cancel.isCancelled) throw const FormatException('다운로드가 취소되었습니다.');
        received += chunk.length;
        if (received > update.size) {
          throw const FormatException('파일 크기가 일치하지 않습니다.');
        }
        sink.add(chunk);
        await sink.flush();
        progress(received / update.size);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await verifyFile(partial, update);
      return await partial.rename(file.path);
    } finally {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  /// Returns false when Android permission settings were opened; retry on return.
  Future<bool> install(File file, ClientUpdate update) async {
    await verifyFile(file, update);
    if (Platform.isAndroid) {
      if (await _channel.invokeMethod<bool>('canInstall') != true) {
        await _channel.invokeMethod<void>('requestInstallPermission');
        return false;
      }
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw StateError('설치 화면을 열지 못했습니다: ${result.message}');
      }
    } else if (Platform.isWindows) {
      await Process.start(file.path, [
        '/DIR=${File(Platform.resolvedExecutable).parent.path}',
        '/SERVERURL=${update.serverUrl}',
        '/CLOSEAPPLICATIONS',
        '/RESTARTAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
    } else {
      throw UnsupportedError('지원하지 않는 플랫폼입니다.');
    }
    return true;
  }
}

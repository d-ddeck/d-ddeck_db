import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

bool get isDesktop => _desktop;

bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 내려받은 파일을 둘 곳. PC 는 사용자의 다운로드 폴더로 고정한다.
/// 휴대폰은 앱이 공용 다운로드 폴더에 바로 쓸 수 없어 임시 폴더에 둔다.
Future<Directory> downloadDirectory() async {
  if (_desktop) {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.create(recursive: true);
  }
  return getTemporaryDirectory();
}

/// 다운로드 폴더에 저장한다. 같은 이름이 있으면 덮어쓰지 않고 '이름 (1).확장자'.
Future<File> saveToDownloads(List<int> bytes, String fileName) async =>
    (await downloadPath(fileName)).writeAsBytes(bytes, flush: true);

/// 다운로드 폴더 안에서 아직 없는 파일 경로.
Future<File> downloadPath(String fileName) async {
  final directory = await downloadDirectory();
  final name = fileName.split(RegExp(r'[/\\]')).last.trim();
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  var file = File('${directory.path}${Platform.pathSeparator}$name');
  for (var n = 1; await file.exists(); n++) {
    file = File('${directory.path}${Platform.pathSeparator}$stem ($n)$ext');
  }
  return file;
}

/// 다운로드 폴더에 저장하고 시스템 앱으로 연다.
Future<File> saveAndOpenDownload(List<int> bytes, String fileName) async {
  final file = await saveToDownloads(bytes, fileName);
  final result = await OpenFilex.open(file.path);
  if (result.type != ResultType.done) throw Exception(result.message);
  return file;
}

/// PDF 를 저장하고 저장한 경로를 돌려준다. 취소하면 null.
/// PC 는 묻지 않고 다운로드 폴더에, 휴대폰은 저장 위치를 묻는다.
Future<String?> savePdfAs(
  List<int> bytes,
  String fileName, {
  required String dialogTitle,
}) async {
  if (_desktop) return (await saveToDownloads(bytes, fileName)).path;
  return FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ['pdf'],
    bytes: Uint8List.fromList(bytes),
  );
}

/// '다운로드 폴더에 저장했습니다: 파일명'
String savedMessage(String path) =>
    '다운로드 폴더에 저장했습니다: ${path.split(RegExp(r'[/\\\\]')).last}';

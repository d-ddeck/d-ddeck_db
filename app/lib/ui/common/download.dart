import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// 호출자가 정한 파일명으로 임시 저장하고 시스템 앱으로 연다.
Future<void> saveAndOpenDownload(List<int> bytes, String fileName) async {
  final directory = await getTemporaryDirectory();
  final name = fileName.split(RegExp(r'[/\\]')).last;
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  final result = await OpenFilex.open(file.path);
  if (result.type != ResultType.done) throw Exception(result.message);
}

/// 저장 위치를 물어 PDF 를 저장한다. 취소하면 false.
Future<bool> savePdfAs(
  List<int> bytes,
  String fileName, {
  required String dialogTitle,
}) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ['pdf'],
    bytes: Uint8List.fromList(bytes),
  );
  if (path == null) return false;
  // Desktop pickers only return a path; mobile pickers write the bytes themselves.
  if (!Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return true;
}

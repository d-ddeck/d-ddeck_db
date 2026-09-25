import 'dart:io';

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

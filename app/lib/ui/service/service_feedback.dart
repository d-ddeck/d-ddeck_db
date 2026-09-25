import 'package:flutter/material.dart';

import '../../core/api_exception.dart';

/// 조회 실패는 재시도 화면과 함께 서버의 한국어 메시지를 알린다.
Future<T> serviceLoad<T>(BuildContext context, Future<T> Function() load) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    return await load();
  } on ApiException catch (error) {
    if (messenger.mounted) messenger.showSnackBar(SnackBar(content: Text(error.message)));
    rethrow;
  }
}

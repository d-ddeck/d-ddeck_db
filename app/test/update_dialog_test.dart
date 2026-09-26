import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddeck_app/services/update_service.dart';
import 'package:ddeck_app/ui/update_dialog.dart';

class FakeUpdates extends UpdateService {
  final completed = Completer<File>();
  CancelToken? token;
  int installs = 0;
  @override
  Future<File> download(
    ClientUpdate update,
    CancelToken cancel,
    void Function(double) progress,
  ) {
    token = cancel;
    progress(0.5);
    return completed.future;
  }

  @override
  Future<bool> install(File file, ClientUpdate update) async {
    installs++;
    return false;
  }
}

void main() {
  final update = ClientUpdate(
    '1.0.8',
    8,
    '1.0.8-8',
    'update.apk',
    100,
    'a' * 64,
    'http://server',
  );
  Widget app(FakeUpdates service) => MaterialApp(
    theme: ThemeData.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => UpdateDialog(service: service, update: update),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  testWidgets('download cancellation never launches installer', (tester) async {
    final service = FakeUpdates();
    await tester.pumpWidget(app(service));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다운로드 및 설치'));
    await tester.pump();
    await tester.tap(find.text('다운로드 취소'));
    await tester.pumpAndSettle();
    expect(service.token!.isCancelled, isTrue);
    service.completed.complete(File('/unused'));
    await tester.pump();
    expect(service.installs, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission settings return keeps a retryable install action', (
    tester,
  ) async {
    final service = FakeUpdates();
    await tester.pumpWidget(app(service));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다운로드 및 설치'));
    service.completed.complete(File('/unused'));
    await tester.pumpAndSettle();
    expect(find.text('설치 계속'), findsOneWidget);
    expect(find.textContaining('설정에서 이 앱의 설치를 허용'), findsOneWidget);
    await tester.tap(find.text('설치 계속'));
    await tester.pumpAndSettle();
    expect(service.installs, 2);
    expect(tester.takeException(), isNull);
  });
}

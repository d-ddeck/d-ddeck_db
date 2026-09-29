import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddeck_app/ui/common/section_main_reporter.dart';

void main() {
  testWidgets('reports main after returning from another tab', (tester) async {
    final states = <bool>[];
    late TabController controller;
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationListener<SectionMainNotification>(
          onNotification: (notification) {
            states.add(notification.isMain);
            return true;
          },
          child: DefaultTabController(
            length: 2,
            child: Builder(
              builder: (context) {
                controller = DefaultTabController.of(context);
                return const SectionMainReporter(child: SizedBox());
              },
            ),
          ),
        ),
      ),
    );
    expect(states.last, isTrue);
    controller.index = 1;
    await tester.pump();
    expect(states.last, isFalse);
    controller.index = 0;
    await tester.pump();
    expect(states.last, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

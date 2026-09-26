import 'package:ddeck_app/ui/common/common.dart';
import 'package:ddeck_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scale in [1.0, 1.5, 2.0]) {
    for (final dark in [false, true]) {
      for (final compact in [false, true]) {
        for (final filters in [false, true]) {
          testWidgets(
            'field labels remain inside filter/dialog scroll $scale/$dark/$compact/$filters',
            (tester) async {
              tester.view.physicalSize = const Size(1440, 900);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              await tester.pumpWidget(
                MaterialApp(
                  theme: dark
                      ? AppTheme.dark(
                          compact: compact,
                        ).copyWith(platform: TargetPlatform.windows)
                      : AppTheme.light(
                          compact: compact,
                        ).copyWith(platform: TargetPlatform.windows),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Builder(
                      builder: (context) {
                        final fields = <Widget>[
                          const SizedBox(
                            width: 360,
                            child: TextField(
                              decoration: InputDecoration(
                                labelText: '이름·이메일 검색',
                                prefixIcon: Icon(Icons.search),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 280,
                            child: DropdownButtonFormField<String>(
                              initialValue: 'all',
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '브랜드 · 전 기간',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'all',
                                  child: Text('전체'),
                                ),
                              ],
                              onChanged: (_) {},
                            ),
                          ),
                        ];
                        return SingleChildScrollView(
                          padding: filters
                              ? EdgeInsets.zero
                              : fieldLabelInsets(context),
                          child: filters
                              ? FilterBar(children: fields)
                              : Column(
                                  children: [
                                    fields.first,
                                    const FormGap(),
                                    fields.last,
                                  ],
                                ),
                        );
                      },
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              for (final filled in [false, true]) {
                if (filled) {
                  await tester.enterText(find.byType(TextField).first, '검색 내용');
                  await tester.pumpAndSettle();
                }
                for (final text in ['이름·이메일 검색', '브랜드 · 전 기간']) {
                  final label = find.text(text);
                  for (final clip
                      in find
                          .ancestor(
                            of: label,
                            matching: find.byType(SingleChildScrollView),
                          )
                          .evaluate()) {
                    expect(
                      tester.getTopLeft(label).dy,
                      greaterThanOrEqualTo(
                        tester.getTopLeft(find.byWidget(clip.widget)).dy,
                      ),
                    );
                  }
                }
                expect(tester.takeException(), isNull);
              }
            },
          );
        }
      }
    }
  }
}

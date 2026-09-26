import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import '../../core/api_client.dart';
import '../../models/common.dart';
import '../common/common.dart';
import 'inventory_page.dart';

class DeliveryComparePage extends StatefulWidget {
  const DeliveryComparePage({super.key, this.storeId});
  final String? storeId;
  @override
  State<DeliveryComparePage> createState() => _DeliveryComparePageState();
}

class _DeliveryComparePageState extends State<DeliveryComparePage> {
  final _serials = TextEditingController();
  bool _busy = false;
  Map<String, dynamic>? _result;
  @override
  void dispose() {
    _serials.dispose();
    super.dispose();
  }

  Future<void> _compare({bool excel = false}) async {
    setState(() => _busy = true);
    await runGuarded(context, () async {
      final api = context.read<ApiClient>();
      dynamic response;
      if (excel) {
        final files = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['xlsx'],
        );
        final file = files?.files.single;
        if (file?.path == null) return;
        response = await api.postMultipart(
          '/inventory/delivery-compare/xlsx',
          FormData.fromMap({
            'store_id': widget.storeId,
            'file': await MultipartFile.fromFile(
              file!.path!,
              filename: file.name,
            ),
          }),
        );
      } else {
        response = await api.post(
          '/inventory/delivery-compare',
          body: {
            'store_id': widget.storeId,
            'serials': _serials.text
                .split(RegExp(r'[\s,;]+'))
                .where((v) => v.isNotEmpty)
                .toList(),
          },
        );
      }
      if (mounted) setState(() => _result = asMap(response));
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('출고 대조')),
    body: PageBody(
      child: FormListView(
        children: [
          const Text('출고 시리얼을 붙여넣거나 시리얼 열이 있는 Excel 파일을 선택하세요.'),
          TextField(
            controller: _serials,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '시리얼 목록'),
          ),
          Wrap(
            runSpacing: 12,
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _compare(),
                child: const Text('대조'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _compare(excel: true),
                child: const Text('Excel 선택'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_result != null) ...[
            for (final key in ['missing', 'duplicates'])
              SectionCard(
                title: key == 'missing' ? '재고에서 찾지 못함' : '출고 목록의 중복',
                child: SelectableText((_result![key] as List).join('\n')),
              ),
            for (final key in ['found', 'unexpected'])
              SectionCard(
                title: key == 'found' ? '일치 장비' : '출고 목록에 없는 매장 장비',
                child: Column(
                  children: [
                    for (final value in _result![key] as List)
                      ListTile(
                        title: Text('${value['name']} · ${value['serial_no']}'),
                        subtitle: Text('${value['status']}'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AssetDetailPage(assetId: '${value['id']}'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    ),
  );
}

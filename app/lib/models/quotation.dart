import 'common.dart';

/// Integer fixed-point arithmetic matches the server's Decimal ROUND_HALF_UP.
/// Quantities have up to three decimal places; prices are whole won.
int? quotationSubtotal(Iterable<Map<String, String>> items) {
  var total = BigInt.zero;
  for (final item in items) {
    final quantity = (item['quantity'] ?? '').trim();
    final price = (item['unit_price'] ?? '').trim();
    if (!RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(quantity) ||
        !RegExp(r'^\d+$').hasMatch(price)) {
      return null;
    }
    final parts = quantity.split('.');
    final milli =
        BigInt.parse(parts.first) * BigInt.from(1000) +
        BigInt.parse(parts.length > 1 ? parts[1].padRight(3, '0') : '0');
    final unit = BigInt.parse(price);
    if (milli <= BigInt.zero ||
        milli > BigInt.from(1000000000) ||
        unit > BigInt.from(10000000000)) {
      return null;
    }
    total += (milli * unit + BigInt.from(500)) ~/ BigInt.from(1000);
  }
  return total.toInt();
}

/// 견적서 체크리스트 항목. 체크하면 [notes] 를 안내사항에, [items] 를 품목에 채운다.
/// 관리자가 서비스 설정(quotation_checklist)에서 관리한다.
class QuoteChecklistEntry {
  const QuoteChecklistEntry({
    required this.id,
    required this.label,
    this.notes = '',
    this.items = const [],
    this.active = true,
  });

  final String id;
  final String label;
  final String notes;

  /// 견적 품목과 같은 키(name, specification, quantity, unit_price, note).
  final List<Map<String, String>> items;
  final bool active;

  static const itemKeys = [
    'name',
    'specification',
    'quantity',
    'unit_price',
    'note',
  ];

  factory QuoteChecklistEntry.fromJson(Map<String, dynamic> j) =>
      QuoteChecklistEntry(
        id: asString(j['id']),
        label: asString(j['label']),
        notes: asString(j['notes']),
        items: [
          for (final raw in j['items'] as List? ?? const [])
            {for (final k in itemKeys) k: asString(asMap(raw)[k]).trim()},
        ],
        active: asBool(j['active'], true),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'notes': notes,
    'items': items,
    'active': active,
  };

  QuoteChecklistEntry copyWith({
    String? label,
    String? notes,
    List<Map<String, String>>? items,
    bool? active,
  }) => QuoteChecklistEntry(
    id: id,
    label: label ?? this.label,
    notes: notes ?? this.notes,
    items: items ?? this.items,
    active: active ?? this.active,
  );
}

/// 안내사항 끝에 [block] 을 한 줄 띄워 덧붙인다. 이미 들어 있으면 그대로 둔다.
String addNotesBlock(String notes, String block) {
  block = block.trim();
  final current = notes.trimRight();
  if (block.isEmpty || current.contains(block)) return notes;
  return current.isEmpty ? block : '$current\n\n$block';
}

/// 안내사항에서 [block] 을 뺀다. 사용자가 고쳐서 그대로 찾을 수 없으면 null.
String? removeNotesBlock(String notes, String block) {
  block = block.trim();
  if (block.isEmpty) return notes;
  if (!notes.contains(block)) return null;
  return notes
      .replaceFirst(block, '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

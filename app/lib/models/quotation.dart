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

import 'package:ddeck_app/ui/common/phone_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _type(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  test('formats Korean numbers by their own pattern', () {
    expect(formatPhoneNumber('01012345678'), '010-1234-5678');
    expect(formatPhoneNumber('010 1234 5678'), '010-1234-5678');
    expect(formatPhoneNumber('0311234567'), '031-123-4567');
    expect(formatPhoneNumber('03112345678'), '031-1234-5678');
    expect(formatPhoneNumber('07012345678'), '070-1234-5678');
    expect(formatPhoneNumber('021234567'), '02-123-4567');
    expect(formatPhoneNumber('0212345678'), '02-1234-5678');
    expect(formatPhoneNumber('15881234'), '1588-1234');
  });

  test('formats partial input while typing', () {
    expect(formatPhoneNumber('010'), '010');
    expect(formatPhoneNumber('0101'), '010-1');
    expect(formatPhoneNumber('0101234'), '010-123-4');
    expect(formatPhoneNumber('01012345'), '010-123-45');
    expect(formatPhoneNumber('0212'), '02-12');
  });

  test('leaves international or annotated numbers alone', () {
    expect(formatPhoneNumber('+82 10-1234-5678'), '+82 10-1234-5678');
    expect(formatPhoneNumber('02-123-4567 내선 3'), '02-123-4567 내선 3');
    expect(formatPhoneNumber(''), '');
  });

  test('typing digit by digit produces 000-0000-0000', () {
    const formatter = PhoneNumberFormatter();
    var value = TextEditingValue.empty;
    for (final digit in '01012345678'.split('')) {
      value = formatter.formatEditUpdate(value, _type(value.text + digit));
    }
    expect(value.text, '010-1234-5678');
    expect(value.selection.end, value.text.length);
  });

  test('backspace over a hyphen removes the digit before it', () {
    const formatter = PhoneNumberFormatter();
    const old = TextEditingValue(
      text: '010-1234-5678',
      selection: TextSelection.collapsed(offset: 9),
    );
    // Backspace at offset 9 deletes the '-' at index 8.
    final value = formatter.formatEditUpdate(
      old,
      const TextEditingValue(
        text: '010-12345678',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    expect(value.text, '010-123-5678');
  });

  test('rejects more than 11 digits and keeps free text editable', () {
    const formatter = PhoneNumberFormatter();
    final full = _type('010-1234-5678');
    expect(formatter.formatEditUpdate(full, _type('010-1234-56789')), full);
    final note = _type('02-123-4567 내');
    expect(formatter.formatEditUpdate(_type('02-123-4567 '), note), note);
  });
}

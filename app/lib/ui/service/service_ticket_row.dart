import 'package:flutter/material.dart';

import '../../models/service.dart';
import '../format.dart';
import '../theme.dart';

/// Shared column proportions keep every desktop row aligned. On small screens
/// (or with enlarged text), use a compact card without horizontal overflow.
class ServiceTicketRow extends StatelessWidget {
  const ServiceTicketRow({
    super.key,
    required this.ticket,
    required this.onTap,
  });
  const ServiceTicketRow.header({super.key}) : ticket = null, onTap = null;
  final ServiceTicket? ticket;
  final VoidCallback? onTap;

  Widget _text(String value, {bool bold = false}) => Tooltip(
    message: value,
    child: Text(
      value,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontWeight: bold ? FontWeight.w600 : null),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide =
          constraints.maxWidth >= 850 &&
          MediaQuery.textScalerOf(context).scale(14) <= 20;
      final t = ticket;
      if (t == null && !wide) return const SizedBox.shrink();
      final status = t == null
          ? const Text('상태')
          : StatusChip(
              label: t.status.label,
              color: t.status.color,
              dense: true,
            );
      if (!wide && t != null) {
        return Card(
          child: ListTile(
            onTap: onTap,
            title: Tooltip(
              message: '${t.displayNo} · ${t.title}',
              child: Text(
                '${t.storeName ?? '매장 미지정'} · ${t.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            subtitle: Text(
              '${t.workTypeLabel} · ${t.displayNo} · ${Fmt.date(t.receivedAt.toLocal())}${t.isRental && !t.rentalReturned ? ' · 렌탈 미회수' : ''}',
            ),
            trailing: status,
          ),
        );
      }
      final cells = <Widget>[
        _text(
          t == null ? '접수번호 / 업무 구분' : '${t.displayNo}\n${t.workTypeLabel}',
        ),
        _text(
          t == null
              ? '매장 / 브랜드'
              : '${t.storeName ?? '미지정'}\n${t.brandName ?? '-'}',
        ),
        if (t == null)
          const Text('발생 내용')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _text(t.title, bold: true),
              Tooltip(
                message:
                    '${t.causeLabels.join(' | ')} · ${t.responderNames.join(', ')} · 첨부 ${t.attachmentCount} · 기록 ${t.logCount}${t.isRental && !t.rentalReturned ? ' · 렌탈 미회수' : ''}',
                child: Text(
                  '${t.causeLabels.join(' | ')} · ${t.responderNames.join(', ')} · 첨부 ${t.attachmentCount} · 기록 ${t.logCount}${t.isRental && !t.rentalReturned ? ' · 렌탈 미회수' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        _text(t == null ? '발생일' : Fmt.date(t.receivedAt.toLocal())),
        _text(t == null ? '대응일' : Fmt.date(t.completedAt?.toLocal())),
        Align(alignment: Alignment.centerLeft, child: status),
      ];
      return Material(
        color: t == null
            ? Theme.of(context).colorScheme.surfaceContainerLow
            : Theme.of(context).colorScheme.surface,
        shape: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: Theme.of(context).visualDensity == VisualDensity.compact
                  ? 8
                  : 14,
            ),
            child: Row(
              children: [
                for (var i = 0; i < cells.length; i++)
                  Expanded(
                    flex: [3, 3, 5, 2, 2, 2][i],
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: cells[i],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/calendar_repository.dart';
import '../../models/calendar.dart';
import '../../state/auth_state.dart';
import '../common/common.dart';
import '../format.dart';
import '../theme.dart';
import 'event_form_page.dart';

class EventDetailSheet extends StatefulWidget {
  const EventDetailSheet({super.key, required this.event, this.onChanged});
  final CalendarEvent event;
  final VoidCallback? onChanged;

  static Future<void> show(
    BuildContext context,
    CalendarEvent event, {
    VoidCallback? onChanged,
  }) async {
    final hostContext = Scaffold.of(context).context;
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => EventDetailSheet(event: event, onChanged: onChanged),
    );
    if (deleted == true && hostContext.mounted) {
      onChanged?.call();
      AppSnack.show(hostContext, '일정이 삭제되었습니다.');
    }
  }

  @override
  State<EventDetailSheet> createState() => _EventDetailSheetState();
}

class _EventDetailSheetState extends State<EventDetailSheet> {
  late CalendarEvent event = widget.event;
  bool _busy = false;

  Future<void> _edit() async {
    setState(() => _busy = true);
    CalendarEvent? updated;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            EventFormPage.edit(event, onSaved: (value) => updated = value),
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) event = updated!;
    });
    if (saved == true) widget.onChanged?.call();
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final confirmed = await ConfirmDialog.show(
      context,
      title: '일정 삭제',
      message: '이 일정을 삭제합니다. 참석자에게 취소 알림이 갑니다.',
      confirmLabel: '삭제',
      destructive: true,
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() => _busy = false);
      return;
    }
    final ok = await runGuarded(
      context,
      () => context.read<CalendarRepository>().deleteEvent(event.id),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final userId = auth.user?.id;
    final canEdit =
        userId != null &&
        (auth.isManager ||
            event.createdById == userId ||
            event.participants.any((p) => p.userId == userId && p.isOrganizer));
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SectionCard(
                title: '일정 정보',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: event.status == EventStatus.canceled
                                ? Colors.grey
                                : event.displayColor(
                                    event.calendar?.displayColor ??
                                        Theme.of(context).colorScheme.primary,
                                  ),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            event.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _row(
                      context,
                      Icons.schedule,
                      Fmt.range(
                        event.startsAt,
                        event.endsAt,
                        allDay: event.allDay,
                      ),
                    ),
                    if (event.location != null)
                      _row(context, Icons.place_outlined, event.location!),
                    if (event.description != null)
                      _row(context, Icons.notes, event.description!),
                    if (event.reminders.isNotEmpty)
                      _row(
                        context,
                        Icons.notifications_outlined,
                        event.reminders
                            .map(
                              (r) => Fmt.dateTime(
                                event.startsAt.subtract(
                                  Duration(minutes: r.offsetMinutes),
                                ),
                              ),
                            )
                            .join(', '),
                      ),
                    const FormGap(),
                    Text(
                      '참석자 ${Fmt.number(event.participants.length)}명',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final p in event.participants)
                          StatusChip(
                            label:
                                '${p.user?.fullName ?? '?'}${p.isOrganizer ? ' (주최)' : ''}',
                            color: p.response.color,
                            icon: p.response.icon,
                            dense: true,
                          ),
                      ],
                    ),
                    if (canEdit) ...[
                      const FormGap(),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _edit,
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('수정'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _delete,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.danger(context),
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onError,
                              ),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('삭제'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );
}

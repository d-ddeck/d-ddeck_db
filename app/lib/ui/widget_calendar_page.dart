import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/calendar_repository.dart';
import '../state/auth_state.dart';
import 'calendar/calendar_page.dart';
import 'calendar/event_detail_sheet.dart';
import 'vpn/vpn_setup_page.dart';

/// A widget click starts an Activity directly, so Android background launch
/// restrictions cannot swallow a connection recovery screen.
class WidgetCalendarPage extends StatefulWidget {
  const WidgetCalendarPage({super.key, this.eventId});
  final String? eventId;
  @override
  State<WidgetCalendarPage> createState() => _WidgetCalendarPageState();
}

class _WidgetCalendarPageState extends State<WidgetCalendarPage> {
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  Future<void> _sync() async {
    if (_busy) return;
    final auth = context.read<AuthState>();
    if (auth.phase != AuthPhase.ready) {
      setState(() => _message = '로그인한 뒤 위젯을 새로고침해 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await auth.syncWidgetCalendar();
      if (!mounted) return;
      setState(() => _message = '캘린더를 동기화했습니다. 위젯에 반영되었습니다.');
      if (widget.eventId?.isNotEmpty == true) {
        final event = await context.read<CalendarRepository>().event(
          widget.eventId!,
        );
        if (mounted) await EventDetailSheet.show(context, event);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              '서버에 연결하거나 일정을 불러오지 못했습니다. VPN·로그인 상태를 확인하고 다시 시도해 주세요. 위젯에는 마지막 저장 내용이 유지됩니다.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = context.watch<AuthState>().phase == AuthPhase.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('위젯 캘린더 동기화')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_message!),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _sync,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 동기화'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const VpnSetupPage()),
            ),
            child: const Text('VPN 연결 설정'),
          ),
          if (!ready)
            OutlinedButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('로그인 화면으로'),
            ),
          if (ready)
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('캘린더')),
                    body: const CalendarPage(),
                  ),
                ),
              ),
              child: const Text('캘린더 열기'),
            ),
        ],
      ),
    );
  }
}

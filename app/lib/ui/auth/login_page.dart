import '../common/theme_mode_button.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_exception.dart';
import '../../core/config.dart';
import '../../state/auth_state.dart';
import '../../services/vpn_service.dart';
import '../../services/alarm_service.dart';
import '../alarm_list_page.dart';
import '../vpn/vpn_controls.dart';
import '../theme.dart';
import '../common/common.dart';
import 'signup_page.dart';
import '../admin/connection_settings_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  bool _rememberMe = true;
  String? _error;
  String? _serverProbe;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthState>();
    auth.tokenStore.readLastEmail().then((value) {
      if (value != null && mounted) _email.text = value;
    });
    auth.readRememberMe().then((value) {
      if (mounted) setState(() => _rememberMe = value);
    });
    // A notice set during a forced logout (session expired, password changed)
    // is shown once here rather than being lost with the previous screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notice = auth.notice;
      if (notice != null && mounted) {
        setState(() => _error = notice);
        auth.clearNotice();
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthState>();
    try {
      await auth.login(_email.text, _password.text, rememberMe: _rememberMe);
      // On success the root widget swaps this page out; nothing to do here.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ping() async {
    setState(() {
      _busy = true;
      _serverProbe = null;
    });
    final auth = context.read<AuthState>();
    try {
      final ok = await auth.pingServer();
      if (!mounted) return;
      setState(() {
        _serverProbe = ok ? '연결 정상' : '서버에 연결할 수 없습니다.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _serverProbe = error is ApiException
              ? error.message
              : '연결 설정을 확인한 뒤 다시 시도해 주세요.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(actions: const [ThemeModeButton(), SizedBox(width: 8)]),
      body: PageBody(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.xl),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.dns_outlined),
                              title: const Text('디떽 업무 서버'),
                              trailing: IconButton(
                                tooltip: '서버 연결 확인',
                                onPressed: _busy ? null : _ping,
                                icon: const Icon(Icons.wifi_tethering),
                              ),
                            ),
                            if (_serverProbe != null)
                              Text(
                                _serverProbe!,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            const FormGap(),
                            Center(
                              child: Image.asset(
                                'assets/icon/app_icon.png',
                                width: 72,
                                height: 72,
                                fit: BoxFit.contain,
                                semanticLabel: '디떽 회사 로고',
                              ),
                            ),
                            const FormGap(),
                            Text(
                              AppConfig.appName,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '사내 통합 DB 서버',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 28),

                            // VPN 이 꺼져 있으면 로그인 자체가 안 되므로 로그인 전에 연결한다.
                            if (VpnService.isSupported) ...[
                              const VpnControls(),
                              const FormGap(),
                            ],

                            TextFormField(
                              controller: _email,
                              decoration: const InputDecoration(
                                labelText: '이메일',
                                prefixIcon: Icon(Icons.mail_outline),
                              ),
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.username],
                              textInputAction: TextInputAction.next,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? '이메일을 입력해 주세요.'
                                  : null,
                            ),
                            const FormGap(),
                            TextFormField(
                              controller: _password,
                              decoration: InputDecoration(
                                labelText: '비밀번호',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _obscure ? '비밀번호 표시' : '비밀번호 숨기기',
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                              obscureText: _obscure,
                              autofillHints: const [AutofillHints.password],
                              onFieldSubmitted: (_) => _busy ? null : _submit(),
                              validator: (v) => (v == null || v.isEmpty)
                                  ? '비밀번호를 입력해 주세요.'
                                  : null,
                            ),

                            // 끄면 리프레시 토큰을 디스크에 남기지 않는다. 공용 PC 에서
                            // 다음 사람이 그대로 들어가는 것을 막기 위한 선택지.
                            CheckboxListTile(
                              value: _rememberMe,
                              onChanged: _busy
                                  ? null
                                  : (v) =>
                                        setState(() => _rememberMe = v ?? true),
                              title: const Text(
                                '자동 로그인',
                                style: TextStyle(fontSize: 14),
                              ),
                              subtitle: Text(
                                _rememberMe
                                    ? '다음부터 바로 시작합니다 (최대 14일)'
                                    : '앱을 닫으면 다시 로그인해야 합니다',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),

                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            const ConnectionSettingsPage(),
                                      ),
                                    ),
                              icon: const Icon(Icons.settings_backup_restore),
                              label: const Text('관리자 연결 설정 가져오기'),
                            ),

                            if (_error != null) ...[
                              const FormGap(),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: scheme.errorContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.error_outline,
                                      size: 18,
                                      color: scheme.onErrorContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _error!,
                                        style: TextStyle(
                                          color: scheme.onErrorContainer,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],

                            const FormGap(),
                            FormActions(
                              child: FilledButton(
                                onPressed: _busy ? null : _submit,
                                child: _busy
                                    ? const SizedBox(
                                        height: 18,
                                        width: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('로그인'),
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => const SignupPage(),
                                      ),
                                    ),
                              child: const Text('회원가입 신청'),
                            ),
                            const FormGap(),
                            const SizedBox(height: 4),
                            Text(
                              '가입 후 관리자 승인이 완료되어야 로그인할 수 있습니다.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (AlarmService.isSupported)
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SyncedAlarmsPage(),
                        ),
                      ),
                      child: const Text('이 폰에 저장된 알람 보기'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown after a successful signup: the account exists but cannot sign in yet.
class SignupSubmittedPage extends StatelessWidget {
  const SignupSubmittedPage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('가입 신청 완료')),
      body: PageBody(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.mark_email_read_outlined,
                    size: 56,
                    color: Colors.green,
                  ),
                  const FormGap(),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '관리자가 승인하면 알림을 받게 되며, 그 후 로그인할 수 있습니다.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const FormGap(),
                  FormActions(
                    child: FilledButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).popUntil((route) => route.isFirst),
                      child: const Text('로그인 화면으로'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Startup splash while the saved session is being restored.
class AuthLoadingPage extends StatelessWidget {
  const AuthLoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: PageBody(child: LoadingState(message: '세션 확인 중...')),
    );
  }
}

/// Reusable inline error box.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
      ),
    );
  }
}

/// Exported so other auth screens can reuse the placeholder styling.
typedef AuthPlaceholder = StatePlaceholder;

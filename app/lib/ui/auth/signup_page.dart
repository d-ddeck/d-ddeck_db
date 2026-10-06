import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../core/api_exception.dart';
import '../../core/latin_input.dart';
import '../../state/auth_state.dart';
import 'login_page.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  final _employeeNo = TextEditingController();
  final _phone = TextEditingController();
  final _position = TextEditingController();
  final _note = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// Field-level messages the server sent back in a 422.
  Map<String, String> _serverFieldErrors = {};

  @override
  void dispose() {
    for (final c in [
      _email,
      _password,
      _confirm,
      _name,
      _employeeNo,
      _phone,
      _position,
      _note,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverFieldErrors = {});
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await context.read<AuthState>().signup(
        email: _email.text,
        password: hangulToQwerty(_password.text),
        fullName: _name.text,
        employeeNo: _employeeNo.text,
        phone: _phone.text,
        position: _position.text,
        signupNote: _note.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SignupSubmittedPage(message: message),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _serverFieldErrors = e.fieldErrors;
      });
      // Re-run validators so the server's field messages appear inline.
      _formKey.currentState!.validate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Mirrors the server rule: 8+ chars, at least one letter and one digit.
  String? _validatePassword(String? v) {
    if (v == null || v.isEmpty) return '비밀번호를 입력해 주세요.';
    final problems = <String>[];
    if (v.length < 8) problems.add('8자 이상');
    if (!v.contains(RegExp(r'[A-Za-z]'))) problems.add('영문 1자 이상');
    if (!v.contains(RegExp(r'[0-9]'))) problems.add('숫자 1자 이상');
    if (problems.isNotEmpty) return '${problems.join(', ')} 필요';
    return _serverFieldErrors['password'];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('회원가입 신청')),
      body: PageBody(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SectionCard(
                title: '가입 정보',
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '신청 후 관리자 승인이 완료되어야 로그인할 수 있습니다.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const FormGap(),

                      _field(
                        controller: _email,
                        label: '이메일 *',
                        icon: Icons.mail_outline,
                        keyboard: TextInputType.emailAddress,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return '이메일을 입력해 주세요.';
                          }
                          if (!RegExp(
                            r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$',
                          ).hasMatch(v.trim())) {
                            return '이메일 형식이 올바르지 않습니다.';
                          }
                          return _serverFieldErrors['email'];
                        },
                      ),
                      _field(
                        controller: _name,
                        label: '이름 *',
                        icon: Icons.badge_outlined,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? '이름을 입력해 주세요.'
                            : _serverFieldErrors['full_name'],
                      ),
                      TextFormField(
                        controller: _password,
                        // 로그인과 같은 규칙: 한/영이 한글이어도 영문으로 들어간다.
                        keyboardType: TextInputType.visiblePassword,
                        inputFormatters: const [LatinInputFormatter()],
                        decoration: InputDecoration(
                          labelText: '비밀번호 *',
                          helperText: '8자 이상, 영문과 숫자를 포함해야 합니다.',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
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
                        validator: _validatePassword,
                      ),
                      const FormGap(),
                      TextFormField(
                        controller: _confirm,
                        // 로그인과 같은 규칙: 한/영이 한글이어도 영문으로 들어간다.
                        keyboardType: TextInputType.visiblePassword,
                        inputFormatters: const [LatinInputFormatter()],
                        decoration: const InputDecoration(
                          labelText: '비밀번호 확인 *',
                          prefixIcon: Icon(Icons.lock_reset_outlined),
                        ),
                        obscureText: _obscure,
                        validator: (v) =>
                            v != _password.text ? '비밀번호가 일치하지 않습니다.' : null,
                      ),
                      const FormGap(),

                      _field(
                        controller: _employeeNo,
                        label: '사번',
                        icon: Icons.tag,
                        validator: (_) => _serverFieldErrors['employee_no'],
                      ),
                      _field(
                        controller: _phone,
                        label: '연락처',
                        icon: Icons.phone_outlined,
                        keyboard: TextInputType.phone,
                        inputFormatters: const [PhoneNumberFormatter()],
                        hint: '010-0000-0000',
                      ),
                      _field(
                        controller: _position,
                        label: '직급',
                        icon: Icons.work_outline,
                      ),
                      TextFormField(
                        controller: _note,
                        decoration: const InputDecoration(
                          labelText: '신청 사유 / 메모',
                          helperText: '관리자가 승인 화면에서 확인합니다.',
                          alignLabelWithHint: true,
                        ),
                        maxLines: 3,
                      ),

                      if (_error != null) ...[
                        const FormGap(),
                        ErrorBanner(message: _error!),
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
                              : const Text('가입 신청'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('이미 계정이 있습니다'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboard,
    List<TextInputFormatter>? inputFormatters,
    String? hint,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
        ),
        validator: validator,
      ),
    );
  }
}

/// Forced password change. Reached when the server sets must_change_password,
/// which happens for the bootstrap admin and after an admin password reset.
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key, this.forced = false});

  final bool forced;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // This revokes every session, so AuthState drops back to the login page.
      await context.read<AuthState>().changePassword(
        hangulToQwerty(_current.text),
        hangulToQwerty(_next.text),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('비밀번호 변경'),
        automaticallyImplyLeading: !widget.forced,
      ),
      body: PageBody(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SectionCard(
                title: '비밀번호 변경',
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.forced)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '초기 비밀번호를 사용 중입니다. 계속하려면 비밀번호를 변경해 주세요.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const FormGap(),
                      TextFormField(
                        controller: _current,
                        // 로그인과 같은 규칙: 한/영이 한글이어도 영문으로 들어간다.
                        keyboardType: TextInputType.visiblePassword,
                        inputFormatters: const [LatinInputFormatter()],
                        decoration: const InputDecoration(
                          labelText: '현재 비밀번호',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        obscureText: true,
                        validator: (v) => (v == null || v.isEmpty)
                            ? '현재 비밀번호를 입력해 주세요.'
                            : null,
                      ),
                      const FormGap(),
                      TextFormField(
                        controller: _next,
                        // 로그인과 같은 규칙: 한/영이 한글이어도 영문으로 들어간다.
                        keyboardType: TextInputType.visiblePassword,
                        inputFormatters: const [LatinInputFormatter()],
                        decoration: const InputDecoration(
                          labelText: '새 비밀번호',
                          helperText: '8자 이상, 영문과 숫자를 포함해야 합니다.',
                          prefixIcon: Icon(Icons.lock_reset_outlined),
                        ),
                        obscureText: true,
                        validator: (v) {
                          if (v == null || v.length < 8) return '8자 이상이어야 합니다.';
                          if (!v.contains(RegExp(r'[A-Za-z]'))) {
                            return '영문을 1자 이상 포함해야 합니다.';
                          }
                          if (!v.contains(RegExp(r'[0-9]'))) {
                            return '숫자를 1자 이상 포함해야 합니다.';
                          }
                          if (v == _current.text) {
                            return '이전과 다른 비밀번호를 사용해 주세요.';
                          }
                          return null;
                        },
                      ),
                      const FormGap(),
                      TextFormField(
                        controller: _confirm,
                        // 로그인과 같은 규칙: 한/영이 한글이어도 영문으로 들어간다.
                        keyboardType: TextInputType.visiblePassword,
                        inputFormatters: const [LatinInputFormatter()],
                        decoration: const InputDecoration(
                          labelText: '새 비밀번호 확인',
                          prefixIcon: Icon(Icons.check_circle_outline),
                        ),
                        obscureText: true,
                        validator: (v) =>
                            v != _next.text ? '비밀번호가 일치하지 않습니다.' : null,
                      ),
                      if (_error != null) ...[
                        const FormGap(),
                        ErrorBanner(message: _error!),
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
                              : const Text('변경하기'),
                        ),
                      ),
                      if (widget.forced) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => context.read<AuthState>().logout(),
                          child: const Text('로그아웃'),
                        ),
                      ],
                      const FormGap(),
                      Text(
                        '변경 후 모든 기기에서 로그아웃되며, 새 비밀번호로 다시 로그인해야 합니다.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

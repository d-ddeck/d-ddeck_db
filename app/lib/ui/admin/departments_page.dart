import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/api_client.dart';
import '../../data/auth_repository.dart';
import '../../models/user.dart';
import '../async_view.dart';
import '../common/common.dart';

class DepartmentsPage extends StatelessWidget {
  const DepartmentsPage({super.key});
  Future<void> _edit(
    BuildContext context,
    VoidCallback reload, [
    Department? department,
  ]) async {
    final name = TextEditingController(text: department?.name),
        code = TextEditingController(text: department?.code);
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text(department == null ? '부서 추가' : '부서 수정'),
        content: Form(
          key: form,
          child: FormFields(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '부서명'),
                validator: (v) =>
                    v?.trim().isNotEmpty == true ? null : '부서명을 입력하세요.',
              ),
              TextFormField(
                controller: code,
                decoration: const InputDecoration(labelText: '부서 코드'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    final body = {
      'name': name.text.trim(),
      'code': code.text.trim().isEmpty ? null : code.text.trim(),
    };
    Future<void>.delayed(const Duration(seconds: 1), () {
      name.dispose();
      code.dispose();
    });
    if (accepted != true || !context.mounted) return;
    final api = context.read<ApiClient>();
    if (await runGuarded(context, () async {
      if (department == null) {
        await api.post('/admin/departments', body: body);
      } else {
        await api.patch('/admin/departments/${department.id}', body: body);
      }
    })) {
      reload();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('부서 관리')),
    body: PageBody(
      child: AsyncView<List<Department>>(
        load: context.read<AuthRepository>().departments,
        builder: (context, rows, reload) => ListView(
          children: [
            FilledButton.icon(
              onPressed: () => _edit(context, reload),
              icon: const Icon(Icons.add),
              label: const Text('부서 추가'),
            ),
            for (final department in rows)
              ListTile(
                title: Text(department.name),
                subtitle: Text(
                  '${department.code ?? '-'} · ${department.userCount}명',
                ),
                onTap: () => _edit(context, reload, department),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '부서 삭제',
                  onPressed: () async {
                    if (!await ConfirmDialog.show(
                      context,
                      title: '부서 삭제',
                      message: '${department.name} 부서를 삭제하시겠습니까?',
                      confirmLabel: '삭제',
                    )) {
                      return;
                    }
                    if (!context.mounted) return;
                    if (await runGuarded(
                      context,
                      () => context.read<ApiClient>().delete(
                        '/admin/departments/${department.id}',
                      ),
                    )) {
                      reload();
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

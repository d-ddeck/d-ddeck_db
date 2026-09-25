import 'package:flutter/material.dart';
import '../format.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';

import '../../data/inventory_repository.dart';
import '../../models/inventory.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import 'asset_destination.dart';
import '../equipment/equipment_page.dart';

class LocationPage extends StatefulWidget {
  const LocationPage({super.key, this.embedded = false, this.onChanged});
  final bool embedded;
  final VoidCallback? onChanged;
  @override
  State<LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<LocationPage> {
  final _key = GlobalKey<AsyncViewState<List<StorageLocation>>>();
  bool _busy = false;

  Iterable<(StorageLocation, int)> _flatten(List<StorageLocation> nodes, [int depth = 0]) sync* {
    for (final node in nodes) {
      yield (node, depth);
      yield* _flatten(node.children, depth + 1);
    }
  }

  Future<void> _delete(StorageLocation location) async {
    final confirmed = await ConfirmDialog.show(context, title: '위치 삭제',
        message: '${location.name} 위치를 삭제하시겠습니까?', confirmLabel: '삭제', destructive: true);
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => context.read<InventoryRepository>().deleteLocation(location.id));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) { _key.currentState?.reload(); widget.onChanged?.call(); }
  }

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AuthState>().isAdmin;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('위치 관리')),
      body: PageBody(child: AsyncView<List<StorageLocation>>(
        key: _key,
        load: () => inventoryLoad(context, context.read<InventoryRepository>().tree),
        builder: (context, nodes, reload) {
          final rows = _flatten(nodes).toList();
          return ListView(padding: EdgeInsets.zero, children: [
            if (admin) Align(alignment: Alignment.centerRight, child: FilledButton.icon(
              icon: const Icon(Icons.add), label: const Text('위치 추가'),
              onPressed: _busy ? null : () async {
                final added = await Navigator.push<bool>(context, MaterialPageRoute(
                  builder: (_) => _LocationForm(locations: rows.map((r) => r.$1).toList()),
                ));
                if (added == true && mounted) { reload(); widget.onChanged?.call(); }
              },
            )),
            if (rows.isEmpty) const EmptyState(message: '아직 등록된 위치가 없습니다'),
            for (final row in rows) Padding(
              // Keep labels usable on phones even for very deep trees.
              padding: EdgeInsets.only(left: (row.$2 * 16.0).clamp(0.0, 96.0)),
              child: ListTile(
                onTap: () => EquipmentPage.open(context, tab: EquipmentTab.assets, locationId: row.$1.id),
                leading: Icon(row.$1.type.icon),
                title: Text(row.$1.name),
                subtitle: Text('${row.$1.code} · ${row.$1.type.label} · 자산 ${Fmt.number(row.$1.assetCount)}개'),
                trailing: admin ? IconButton(tooltip: '삭제', icon: const Icon(Icons.delete_outline),
                  onPressed: _busy ? null : () => _delete(row.$1)) : null,
              ),
            ),
          ]);
        },
      )),
    );
  }
}

class _LocationForm extends StatefulWidget {
  const _LocationForm({required this.locations});
  final List<StorageLocation> locations;
  @override
  State<_LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends State<_LocationForm> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _name = TextEditingController();
  LocationType _type = LocationType.site;
  String? _parentId;
  bool _busy = false;

  @override
  void dispose() { _code.dispose(); _name.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await runGuarded(context, () => context.read<InventoryRepository>().createLocation(
      code: _code.text.trim(), name: _name.text.trim(), type: _type, parentId: _parentId,
    ));
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('위치 추가')),
    body: PageBody(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560),
      child: Form(key: _form, child: ListView(padding: EdgeInsets.zero, children: [
        TextFormField(controller: _code, decoration: const InputDecoration(labelText: '코드 *'),
          validator: (v) => v == null || v.trim().isEmpty ? '코드를 입력해 주세요.' : null),
        const FormGap(),
        TextFormField(controller: _name, decoration: const InputDecoration(labelText: '이름 *'),
          validator: (v) => v == null || v.trim().isEmpty ? '이름을 입력해 주세요.' : null),
        const FormGap(),
        DropdownButtonFormField<LocationType>(initialValue: _type,
          decoration: const InputDecoration(labelText: '종류'),
          items: [for (final t in LocationType.values) DropdownMenuItem(value: t, child: Text(t.label))],
          onChanged: (v) => setState(() => _type = v ?? _type)),
        const FormGap(),
        inventoryChoice('상위 위치', _parentId, {for (final l in widget.locations) l.id: l.display},
          (v) => setState(() => _parentId = v), empty: '없음 (최상위)'),
        const SizedBox(height: 20),
        if (context.watch<AuthState>().isAdmin) FormActions(child: FilledButton(
          onPressed: _busy ? null : _save, child: Text(_busy ? '저장 중…' : '추가'))),
      ])),
    ))),
  );
}

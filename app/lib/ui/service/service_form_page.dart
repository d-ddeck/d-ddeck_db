import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../data/auth_repository.dart';
import '../../data/service_repository.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../async_view.dart';

/// The lookups the intake form needs, loaded in one parallel round.
class _FormOptions {
  const _FormOptions({
    required this.categories,
    required this.symptoms,
    required this.customers,
    required this.members,
  });

  final List<CodeItem> categories;
  final List<CodeItem> symptoms;
  final List<Customer> customers;
  final List<UserBrief> members;
}

/// AS intake form.
///
/// Every dropdown is populated from the server's code master, so an admin
/// editing 서비스 분류 in the settings screen changes this form with no
/// client release.
class ServiceFormPage extends StatefulWidget {
  const ServiceFormPage({super.key, this.ticket});

  /// null 이면 신규 접수, 아니면 그 건을 고친다.
  ///
  /// 상태만은 여기서 못 바꾼다. 상태는 /status 로만 움직여야 타임라인과
  /// 처리 이력이 같이 따라오기 때문에, 상세 화면의 상태 버튼이 그 자리다.
  final ServiceTicket? ticket;

  @override
  State<ServiceFormPage> createState() => _ServiceFormPageState();
}

class _ServiceFormPageState extends State<ServiceFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _customerName = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _product = TextEditingController();
  final _model = TextEditingController();
  final _serial = TextEditingController();
  final _description = TextEditingController();

  String? _customerId;
  String? _categoryId;
  String? _symptomId;
  String? _assigneeId;
  ServicePriority _priority = ServicePriority.normal;
  ServiceChannel _channel = ServiceChannel.phone;
  bool _isWarranty = true;
  bool _busy = false;

  bool get _isEdit => widget.ticket != null;

  @override
  void initState() {
    super.initState();
    final t = widget.ticket;
    if (t == null) return;
    _title.text = t.title;
    _customerName.text = t.customerName ?? '';
    _phone.text = t.contactPhone ?? '';
    _address.text = t.siteAddress ?? '';
    _product.text = t.productName ?? '';
    _model.text = t.modelName ?? '';
    _serial.text = t.serialNo ?? '';
    _description.text = t.description ?? '';
    _customerId = t.customerId;
    _categoryId = t.categoryId;
    _symptomId = t.symptomId;
    _assigneeId = t.assigneeId;
    _priority = t.priority;
    _channel = t.channel;
    _isWarranty = t.isWarranty;
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _customerName,
      _phone,
      _address,
      _product,
      _model,
      _serial,
      _description,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final adminRepo = context.read<AdminRepository>();
    final serviceRepo = context.read<ServiceRepository>();
    final authRepo = context.read<AuthRepository>();

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'AS 수정' : 'AS 접수')),
      body: AsyncView<_FormOptions>(
        load: () async {
          final results = await Future.wait([
            adminRepo.codeGroup('SERVICE_CATEGORY'),
            adminRepo.codeGroup('SERVICE_SYMPTOM'),
            serviceRepo.customers(size: 100),
            authRepo.directory(size: 100),
          ]);
          return _FormOptions(
            categories: (results[0] as CodeGroup).selectable,
            symptoms: (results[1] as CodeGroup).selectable,
            customers: (results[2] as PagedList<Customer>).items,
            members: (results[3] as PagedList<UserBrief>).items,
          );
        },
        builder: (context, options, reload) => Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(labelText: '제목 *'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '제목을 입력해 주세요.' : null,
              ),
              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                initialValue: _customerId,
                decoration: const InputDecoration(labelText: '거래처'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('직접 입력')),
                  for (final c in options.customers)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() {
                  _customerId = v;
                  // Pre-fill contact details from the chosen customer so the
                  // technician does not retype them.
                  if (v != null) {
                    final c = options.customers.firstWhere((x) => x.id == v);
                    _phone.text = c.phone ?? '';
                    _address.text = c.address ?? '';
                  }
                }),
              ),
              if (_customerId == null) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _customerName,
                  decoration: const InputDecoration(labelText: '거래처명 (직접 입력)'),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(labelText: '연락처'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _address,
                decoration: const InputDecoration(labelText: '현장 주소'),
              ),

              const Divider(height: 32),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _categoryId,
                      decoration: const InputDecoration(labelText: '서비스 분류'),
                      isExpanded: true,
                      items: [
                        for (final c in options.categories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _symptomId,
                      decoration: const InputDecoration(labelText: '증상'),
                      isExpanded: true,
                      items: [
                        for (final s in options.symptoms)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: (v) => setState(() => _symptomId = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _product,
                decoration: const InputDecoration(labelText: '제품명'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _model,
                      decoration: const InputDecoration(labelText: '모델'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _serial,
                      decoration: const InputDecoration(labelText: '시리얼'),
                    ),
                  ),
                ],
              ),

              const Divider(height: 32),
              DropdownButtonFormField<String>(
                initialValue: _assigneeId,
                decoration: const InputDecoration(labelText: '담당자'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('미배정')),
                  for (final m in options.members)
                    DropdownMenuItem(value: m.id, child: Text(m.display)),
                ],
                onChanged: (v) => setState(() => _assigneeId = v),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<ServicePriority>(
                      initialValue: _priority,
                      decoration: const InputDecoration(labelText: '우선순위'),
                      isExpanded: true,
                      items: [
                        for (final p in ServicePriority.values)
                          DropdownMenuItem(value: p, child: Text(p.label)),
                      ],
                      onChanged: (v) =>
                          setState(() => _priority = v ?? _priority),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<ServiceChannel>(
                      initialValue: _channel,
                      decoration: const InputDecoration(labelText: '접수 경로'),
                      isExpanded: true,
                      items: [
                        for (final c in ServiceChannel.values)
                          DropdownMenuItem(value: c, child: Text(c.label)),
                      ],
                      onChanged: (v) => setState(() => _channel = v ?? _channel),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('보증 수리', style: TextStyle(fontSize: 14)),
                subtitle: const Text('끄면 유상 처리로 집계됩니다.',
                    style: TextStyle(fontSize: 12)),
                value: _isWarranty,
                onChanged: (v) => setState(() => _isWarranty = v),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: '접수 내용',
                  alignLabelWithHint: true,
                ),
                maxLines: 4,
              ),

              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isEdit ? '저장' : '접수 등록'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final repo = context.read<ServiceRepository>();
    final ok = await runGuarded(
      context,
      () async {
        if (_isEdit) {
          // PATCH 는 보낸 칸만 바꾼다. 비운 칸을 지우려면 null 을 명시해야
          // 하므로 전 칸을 싣는다.
          await repo.update(widget.ticket!.id, {
            'title': _title.text.trim(),
            'customer_id': _customerId,
            'customer_name':
                _customerId == null && _customerName.text.trim().isNotEmpty
                    ? _customerName.text.trim()
                    : null,
            'contact_phone': _nullIfBlank(_phone.text),
            'site_address': _nullIfBlank(_address.text),
            'product_name': _nullIfBlank(_product.text),
            'model_name': _nullIfBlank(_model.text),
            'serial_no': _nullIfBlank(_serial.text),
            'category_id': _categoryId,
            'symptom_id': _symptomId,
            'assignee_id': _assigneeId,
            'priority': _priority.value,
            'channel': _channel.value,
            'is_warranty': _isWarranty,
            'description': _nullIfBlank(_description.text),
          });
          return;
        }
        await repo.create(
              title: _title.text.trim(),
              customerId: _customerId,
              customerName:
                  _customerId == null && _customerName.text.trim().isNotEmpty
                      ? _customerName.text.trim()
                      : null,
              contactPhone: _phone.text.trim().isEmpty ? null : _phone.text,
              siteAddress: _address.text.trim().isEmpty ? null : _address.text,
              productName: _product.text.trim().isEmpty ? null : _product.text,
              modelName: _model.text.trim().isEmpty ? null : _model.text,
              serialNo: _serial.text.trim().isEmpty ? null : _serial.text,
              categoryId: _categoryId,
              symptomId: _symptomId,
              assigneeId: _assigneeId,
              priority: _priority,
              channel: _channel,
              isWarranty: _isWarranty,
              description: _description.text.trim().isEmpty
                  ? null
                  : _description.text.trim(),
            );
      },
      successMessage: _isEdit ? '수정되었습니다.' : 'AS가 접수되었습니다.',
    );

    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  static String? _nullIfBlank(String v) => v.trim().isEmpty ? null : v.trim();
}

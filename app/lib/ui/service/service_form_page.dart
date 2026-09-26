import '../common/save_attachment_button.dart';
import 'service_detail_page.dart';
import 'quotation_page.dart';

import 'package:flutter/services.dart';

import '../common/form_attachments_page.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/common.dart';
import '../common/inventory_serial_field.dart';

import '../../core/api_exception.dart';
import '../../data/admin_repository.dart';
import '../../data/auth_repository.dart';
import '../../data/service_repository.dart';
import '../../data/store_repository.dart';
import '../../models/admin.dart';
import '../../models/common.dart';
import '../../models/service.dart';
import '../../models/store.dart';
import '../../state/auth_state.dart';
import '../async_view.dart';
import '../format.dart';
import '../theme.dart';

class _FormOptions {
  const _FormOptions(this.codes, this.brands, this.customers, this.members);
  final Map<String, List<CodeItem>> codes;
  final List<BrandSummary> brands;
  final List<Customer> customers;
  final List<UserBrief> members;
  List<CodeItem> items(String group) => codes[group] ?? [];
}

class _CauseInput {
  _CauseInput({this.categoryId, this.symptomId, this.makerId});
  String? categoryId;
  String? symptomId;
  String? makerId;
  Map<String, dynamic> toJson() => {
    'category_id': categoryId,
    'symptom_id': symptomId,
    'maker_id': makerId,
  };
}

class ServiceFormPage extends StatefulWidget {
  const ServiceFormPage({
    super.key,
    this.ticket,
    this.initialStoreId,
    this.initialBrandId,
  });
  final ServiceTicket? ticket;
  final String? initialStoreId;
  final String? initialBrandId;

  @override
  State<ServiceFormPage> createState() => _ServiceFormPageState();
}

class _ServiceFormPageState extends State<ServiceFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _customerName = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _product = TextEditingController();
  final _model = TextEditingController();
  final _serial = TextEditingController();
  final _description = TextEditingController();
  final _rentalController = TextEditingController();
  final _rentalField = GlobalKey<InventorySerialFieldState>();
  String get _rentalSerials => _rentalController.text;
  set _rentalSerials(String value) => _rentalController.text = value;
  String? _customerId, _assigneeId, _brandId, _storeId, _faultId, _rentalTypeId;
  String? _workTypeId;
  DateTime _receivedAt = DateTime.now();
  DateTime? _rentalDueDate, _rentalReturnDate;
  bool _isRental = false, _rentalReturned = false;
  final List<_CauseInput> _causes = [];
  final Set<String> _responders = {};
  List<String> _makerCategories = ['로봇팔', '제어박스', '전동 그리퍼'];
  List<Store> _stores = [];
  bool _storesLoading = false;
  int _storeRequest = 0;
  bool _defaultsLoaded = false;
  final _sectionKeys = {
    for (final name in ['매장', '발생', '원인', '대응', '렌탈', '기타']) name: GlobalKey(),
  };
  Set<FormFieldState<Object?>> _invalidFields = {};
  ServicePriority _priority = ServicePriority.normal;
  ServiceChannel _channel = ServiceChannel.phone;
  bool _isWarranty = true;
  bool _busy = false;
  bool get _isEdit => widget.ticket != null;

  @override
  void initState() {
    super.initState();
    final t = widget.ticket;
    _brandId = t?.store?.brandId ?? widget.initialBrandId;
    _storeId = t?.storeId ?? widget.initialStoreId;
    if (t != null) {
      _workTypeId = t.workTypeId;
      _customerName.text = t.customerName ?? '';
      _phone.text = t.contactPhone ?? '';
      _address.text = t.siteAddress ?? '';
      _product.text = t.productName ?? '';
      _model.text = t.modelName ?? '';
      _serial.text = t.serialNo ?? '';
      _description.text = t.description ?? t.title;
      _customerId = t.customerId;
      _assigneeId = t.assigneeId;
      _priority = t.priority;
      _channel = t.channel;
      _isWarranty = t.isWarranty;
      _receivedAt = t.receivedAt.toLocal();
      _faultId = t.faultId;
      _responders.addAll(t.responders.map((r) => r.id));
      _causes.addAll(
        t.causes.map(
          (c) => _CauseInput(
            categoryId: c.categoryId,
            symptomId: c.symptomId,
            makerId: c.makerId,
          ),
        ),
      );
      _isRental = t.isRental;
      _rentalTypeId = t.rentalTypeId;
      _rentalSerials = t.rentalSerials ?? '';
      _rentalDueDate = t.rentalDueDate;
      _rentalReturned = t.rentalReturned;
      _rentalReturnDate = t.rentalReturnDate;
    }
    if (_causes.isEmpty) {
      _causes.add(
        _CauseInput(categoryId: t?.categoryId, symptomId: t?.symptomId),
      );
    }
  }

  void _goTo(BuildContext? target) {
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        alignment: 0.08,
      );
    }
  }

  @override
  void dispose() {
    _rentalController.dispose();
    for (final c in [
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

  Future<_FormOptions> _loadOptions() async {
    final admin = context.read<AdminRepository>();
    final stores = context.read<StoreRepository>();
    final service = context.read<ServiceRepository>();
    final auth = context.read<AuthRepository>();
    final userName = context.read<AuthState>().user?.fullName;
    const groups = [
      'SERVICE_WORK_TYPE',
      'SERVICE_CATEGORY',
      'SERVICE_SYMPTOM',
      'ASSET_CATEGORY',
      'ASSET_MAKER',
      'SERVICE_FAULT',
      'SERVICE_RESPONDER',
      'SERVICE_RENTAL_TYPE',
    ];
    final codes = <String, List<CodeItem>>{};
    final results = await Future.wait<dynamic>([
      Future.wait(
        groups.map((g) async {
          codes[g] = (await admin.codeGroup(g)).items;
        }),
      ),
      stores.brands(),
      service.customers(size: 100),
      auth.directory(size: 100),
      admin
          .settings(SettingsModule.service)
          .then((settings) {
            for (final setting in settings.settings) {
              if (setting.key == 'maker_required_categories') {
                _makerCategories = setting.asStringList;
              }
            }
          })
          .catchError((Object error) {
            // 설정 조회 실패는 기본 규칙으로 계속 진행한다.
            if (error is ApiException && mounted) {
              AppSnack.show(context, error.message, error: true);
            }
          }),
    ]);
    final previousType = widget.ticket?.workType;
    if (previousType != null &&
        !codes['SERVICE_WORK_TYPE']!.any((c) => c.id == previousType.id)) {
      codes['SERVICE_WORK_TYPE']!.add(
        CodeItem(
          id: previousType.id,
          code: previousType.code,
          name: previousType.name,
          isActive: false,
        ),
      );
    }
    if (!_defaultsLoaded) {
      if (!_isEdit) {
        _workTypeId = codes['SERVICE_WORK_TYPE']!
            .where((c) => c.code == 'AS' && c.isActive)
            .firstOrNull
            ?.id;
        _responders.addAll(
          (codes['SERVICE_RESPONDER'] ?? [])
              .where((c) => c.isActive && c.name == userName)
              .map((c) => c.id),
        );
      }
      _defaultsLoaded = true;
    }
    Store? selected;
    if (_storeId != null) {
      selected = await stores.get(_storeId!);
      _brandId = selected.brandId;
    }
    _stores = await stores.all(brandId: _brandId, includeClosed: true);
    if (selected != null && !_stores.any((s) => s.id == selected!.id)) {
      _stores = [..._stores, selected];
    }
    return _FormOptions(
      codes,
      results[1] as List<BrandSummary>,
      (results[2] as PagedList<Customer>).items,
      (results[3] as PagedList<UserBrief>).items,
    );
  }

  Future<void> _changeBrand(String? brand) async {
    final request = ++_storeRequest;
    setState(() {
      _brandId = brand;
      _storeId = null;
      _stores = [];
      _storesLoading = true;
    });
    await runGuarded(context, () async {
      final page = await context.read<StoreRepository>().all(
        brandId: brand,
        includeClosed: true,
      );
      if (mounted && request == _storeRequest) setState(() => _stores = page);
    });
    if (mounted && request == _storeRequest) {
      setState(() => _storesLoading = false);
    }
  }

  Widget _code(
    String label,
    String? value,
    List<CodeItem> items,
    ValueChanged<String?> changed, {
    bool required = false,
    bool enabled = true,
  }) {
    final choices = items.where((c) => c.isActive || c.id == value).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label:$value:${choices.map((c) => c.id).join(',')}'),
        initialValue: choices.any((c) => c.id == value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: '$label${required ? ' *' : ''}'),
        items: [
          const DropdownMenuItem<String>(value: '', child: Text('선택 안 함')),
          for (final c in choices)
            DropdownMenuItem(
              value: c.id,
              child: Text(
                label == '업무 구분'
                    ? '${c.code} · ${c.name}${c.isActive ? '' : ' (사용 중지)'}'
                    : c.name,
              ),
            ),
        ],
        onChanged: enabled ? (v) => changed(v == '' ? null : v) : null,
        validator: (v) =>
            required && (v == null || v.isEmpty) ? '$label을 선택해 주세요.' : null,
      ),
    );
  }

  Widget _date(
    String label,
    DateTime? date,
    ValueChanged<DateTime> changed, {
    bool required = false,
  }) => FormField<DateTime>(
    key: ValueKey('$label:$date'),
    validator: (_) => required && date == null ? '$label을 선택해 주세요.' : null,
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text('$label: ${date == null ? '선택' : Fmt.date(date)}'),
          onPressed: () async {
            final picked = await pickDate(
              context,
              date ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2100, 12, 31),
            );
            if (picked != null && mounted) setState(() => changed(picked));
          },
        ),
        if (field.hasError)
          Text(
            field.errorText!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const FormGap(),
      ],
    ),
  );

  Widget _cause(_CauseInput row, int index, _FormOptions options) {
    final categories = options.items('SERVICE_CATEGORY');
    final category = categories
        .where((c) => c.id == row.categoryId)
        .firstOrNull;
    final assetCategory = options
        .items('ASSET_CATEGORY')
        .where((c) => c.name == category?.name)
        .firstOrNull;
    final symptoms = options
        .items('SERVICE_SYMPTOM')
        .where((c) => c.parentId == row.categoryId && row.categoryId != null)
        .toList();
    final makers = options
        .items('ASSET_MAKER')
        .where((c) => assetCategory != null && c.parentId == assetCategory.id)
        .toList();
    final fields = [
      _code(
        '서비스구분 ${index + 1}',
        row.categoryId,
        categories,
        (v) => setState(() {
          row.categoryId = v;
          row.symptomId = null;
          row.makerId = null;
        }),
        required: index == 0,
      ),
      _code(
        '세부분류 ${index + 1}',
        row.symptomId,
        symptoms,
        (v) => setState(() => row.symptomId = v),
        enabled: symptoms.isNotEmpty,
      ),
      if (_makerCategories.contains(category?.name))
        _code(
          '제조사 ${index + 1}',
          row.makerId,
          makers,
          (v) => setState(() => row.makerId = v),
          required: true,
        ),
    ];
    return Card(
      key: ObjectKey(row),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (AppTheme.isWide(context))
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final field in fields)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: field,
                      ),
                    ),
                ],
              )
            else
              ...fields,
            if (_causes.length > 1)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => setState(() => _causes.remove(row)),
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('삭제'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
        if (!_busy && !_storesLoading && _formKey.currentState != null) {
          _submit();
        }
      },
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '대응 기록 수정' : '대응 기록 접수'),
        actions: [
          SaveAttachmentButton(
            onPressed: _busy || _storesLoading
                ? null
                : () => _submit(attachments: true),
          ),
        ],
      ),
      body: PageBody(
        child: AsyncView<_FormOptions>(
          load: () => guardedLoad(context, _loadOptions),
          builder: (context, options, reload) => DirtyFormScope(
            busy: _busy,
            snapshot: () => [
              _customerName.text,
              _phone.text,
              _address.text,
              _product.text,
              _model.text,
              _serial.text,
              _description.text,
              _rentalSerials,
              _customerId,
              _assigneeId,
              _brandId,
              _storeId,
              _faultId,
              _rentalTypeId,
              _receivedAt,
              _rentalDueDate,
              _rentalReturnDate,
              _isRental,
              _rentalReturned,
              _causes.map((c) => c.toJson()).toList(),
              _responders.toList(),
              _priority,
              _channel,
              _isWarranty,
            ].toString(),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '필수: 매장 · 발생 내용 · 서비스구분 (* 표시 항목)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final section in _sectionKeys.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              label: Text(section.key),
                              onPressed: () =>
                                  _goTo(section.value.currentContext),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_invalidFields.any(
                    (field) => field.mounted && field.hasError,
                  ))
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 100),
                      child: SingleChildScrollView(
                        child: Wrap(
                          runSpacing: 12,
                          spacing: 8,
                          children: [
                            for (final field in _invalidFields.where(
                              (f) => f.mounted && f.hasError,
                            ))
                              ActionChip(
                                avatar: Icon(
                                  Icons.error_outline,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                label: Text(
                                  field.errorText ?? '필수 항목을 확인해 주세요',
                                ),
                                onPressed: () => _goTo(field.context),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: AbsorbPointer(
                        absorbing: _busy,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FormSection(
                              key: _sectionKeys['매장'],
                              title: '매장',
                              children: [
                                DropdownButtonFormField<String>(
                                  key: ValueKey('brand:$_brandId'),
                                  initialValue:
                                      options.brands.any(
                                        (b) => b.brandId == _brandId,
                                      )
                                      ? _brandId
                                      : null,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '브랜드',
                                  ),
                                  items: [
                                    const DropdownMenuItem<String>(
                                      value: '',
                                      child: Text('전체 / 미지정'),
                                    ),
                                    for (final b in options.brands.where(
                                      (b) => b.brandId != null,
                                    ))
                                      DropdownMenuItem(
                                        value: b.brandId,
                                        child: Text(b.brandName),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      _changeBrand(v == '' ? null : v),
                                ),

                                DropdownButtonFormField<String>(
                                  key: ValueKey(
                                    'store:$_brandId:$_storeId:$_storesLoading',
                                  ),
                                  initialValue: _storeId,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: _storesLoading
                                        ? '매장 불러오는 중'
                                        : '매장 *',
                                  ),
                                  items: [
                                    for (final s in _stores)
                                      DropdownMenuItem(
                                        value: s.id,
                                        child: Text(
                                          '${s.name}${s.isClosed ? ' (폐점)' : ''}',
                                        ),
                                      ),
                                  ],
                                  onChanged: _storesLoading
                                      ? null
                                      : (v) => setState(() => _storeId = v),
                                  validator: (v) =>
                                      v == null ? '매장을 선택해 주세요.' : null,
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              key: _sectionKeys['발생'],
                              title: '발생',
                              children: [
                                _date(
                                  '발생일',
                                  _receivedAt,
                                  (v) => _receivedAt = v,
                                  required: true,
                                ),
                                _code(
                                  '업무 구분',
                                  _workTypeId,
                                  options.items('SERVICE_WORK_TYPE'),
                                  (v) => setState(() => _workTypeId = v),
                                ),
                                TextFormField(
                                  controller: _description,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                    labelText: '발생 내용 *',
                                    alignLabelWithHint: true,
                                  ),
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                      ? '발생 내용을 입력해 주세요.'
                                      : null,
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              key: _sectionKeys['원인'],
                              title: '원인',
                              children: [
                                _code(
                                  '과실',
                                  _faultId,
                                  options.items('SERVICE_FAULT'),
                                  (v) => setState(() => _faultId = v),
                                ),
                                for (var i = 0; i < _causes.length; i++)
                                  _cause(_causes[i], i, options),
                                TextButton.icon(
                                  onPressed: _causes.length >= 10
                                      ? null
                                      : () => setState(
                                          () => _causes.add(_CauseInput()),
                                        ),
                                  icon: const Icon(Icons.add),
                                  label: const Text('서비스구분 추가'),
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              key: _sectionKeys['대응'],
                              title: '대응',
                              children: [
                                const Text('대응인원'),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: AppSpace.md,
                                  children: [
                                    for (final r
                                        in options
                                            .items('SERVICE_RESPONDER')
                                            .where(
                                              (r) =>
                                                  r.isActive ||
                                                  _responders.contains(r.id),
                                            ))
                                      FilterChip(
                                        label: Text(r.name),
                                        selected: _responders.contains(r.id),
                                        onSelected: (v) => setState(() {
                                          v
                                              ? _responders.add(r.id)
                                              : _responders.remove(r.id);
                                        }),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              key: _sectionKeys['렌탈'],
                              title: '렌탈',
                              children: [
                                SwitchListTile(
                                  title: const Text('렌탈'),
                                  value: _isRental,
                                  onChanged: (v) =>
                                      setState(() => _isRental = v),
                                ),
                                if (_isRental) ...[
                                  _code(
                                    '렌탈 장비 종류',
                                    _rentalTypeId,
                                    options.items('SERVICE_RENTAL_TYPE'),
                                    (v) => setState(() => _rentalTypeId = v),
                                    required: true,
                                  ),
                                  InventorySerialField(
                                    key: _rentalField,
                                    controller: _rentalController,
                                    label: '렌탈 장비 시리얼 *',
                                    optional: false,
                                    multiple: true,
                                  ),

                                  _date(
                                    '회수 예정일',
                                    _rentalDueDate,
                                    (v) => _rentalDueDate = v,
                                    required: true,
                                  ),
                                  SwitchListTile(
                                    title: const Text('회수 여부'),
                                    value: _rentalReturned,
                                    onChanged: (v) async {
                                      if (v &&
                                          !await ConfirmDialog.show(
                                            context,
                                            title: '렌탈 회수',
                                            message: '렌탈 장비를 회수 처리하시겠습니까?',
                                            confirmLabel: '회수',
                                            destructive: true,
                                          )) {
                                        return;
                                      }
                                      if (mounted) {
                                        setState(() => _rentalReturned = v);
                                      }
                                    },
                                  ),
                                  if (_rentalReturned)
                                    _date(
                                      '실제 회수일',
                                      _rentalReturnDate,
                                      (v) => _rentalReturnDate = v,
                                      required: true,
                                    ),
                                ],
                              ],
                            ),
                            const FormGap(),
                            FormSection(
                              key: _sectionKeys['기타'],
                              title: '기타',
                              children: [
                                DropdownButtonFormField<String>(
                                  initialValue: _customerId,
                                  decoration: const InputDecoration(
                                    labelText: '거래처',
                                  ),
                                  isExpanded: true,
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('직접 입력'),
                                    ),
                                    for (final c in options.customers)
                                      DropdownMenuItem(
                                        value: c.id,
                                        child: Text(c.name),
                                      ),
                                  ],
                                  onChanged: (v) => setState(() {
                                    _customerId = v;
                                    // Pre-fill contact details from the chosen customer so the
                                    // technician does not retype them.
                                    if (v != null) {
                                      final c = options.customers.firstWhere(
                                        (x) => x.id == v,
                                      );
                                      _phone.text = c.phone ?? '';
                                      _address.text = c.address ?? '';
                                    }
                                  }),
                                ),
                                if (_customerId == null) ...[
                                  TextFormField(
                                    controller: _customerName,
                                    decoration: const InputDecoration(
                                      labelText: '거래처명 (직접 입력)',
                                    ),
                                  ),
                                ],

                                TextFormField(
                                  controller: _phone,
                                  decoration: const InputDecoration(
                                    labelText: '연락처',
                                  ),
                                  keyboardType: TextInputType.phone,
                                ),

                                TextFormField(
                                  controller: _address,
                                  decoration: const InputDecoration(
                                    labelText: '현장 주소',
                                  ),
                                ),

                                TextFormField(
                                  controller: _product,
                                  decoration: const InputDecoration(
                                    labelText: '제품명',
                                  ),
                                ),

                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        controller: _model,
                                        decoration: const InputDecoration(
                                          labelText: '모델',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _serial,
                                        decoration: const InputDecoration(
                                          labelText: '시리얼',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),

                                const Divider(height: 32),
                                DropdownButtonFormField<String>(
                                  initialValue: _assigneeId,
                                  decoration: const InputDecoration(
                                    labelText: '담당자',
                                  ),
                                  isExpanded: true,
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('미배정'),
                                    ),
                                    for (final m in options.members)
                                      DropdownMenuItem(
                                        value: m.id,
                                        child: Text(m.display),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _assigneeId = v),
                                ),

                                Row(
                                  children: [
                                    Expanded(
                                      child:
                                          DropdownButtonFormField<
                                            ServicePriority
                                          >(
                                            initialValue: _priority,
                                            decoration: const InputDecoration(
                                              labelText: '우선순위',
                                            ),
                                            isExpanded: true,
                                            items: [
                                              for (final p
                                                  in ServicePriority.values)
                                                DropdownMenuItem(
                                                  value: p,
                                                  child: Text(p.label),
                                                ),
                                            ],
                                            onChanged: (v) => setState(
                                              () => _priority = v ?? _priority,
                                            ),
                                          ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child:
                                          DropdownButtonFormField<
                                            ServiceChannel
                                          >(
                                            initialValue: _channel,
                                            decoration: const InputDecoration(
                                              labelText: '접수 경로',
                                            ),
                                            isExpanded: true,
                                            items: [
                                              for (final c
                                                  in ServiceChannel.values)
                                                DropdownMenuItem(
                                                  value: c,
                                                  child: Text(c.label),
                                                ),
                                            ],
                                            onChanged: (v) => setState(
                                              () => _channel = v ?? _channel,
                                            ),
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    '보증 수리',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                  subtitle: const Text(
                                    '끄면 유상 처리로 집계됩니다.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  value: _isWarranty,
                                  onChanged: (v) =>
                                      setState(() => _isWarranty = v),
                                ),
                              ],
                            ),
                            const FormGap(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  FormActions(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton(
                          onPressed: _busy || _storesLoading ? null : _submit,
                          child: Text(_busy ? '저장 중…' : '저장'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _busy || _storesLoading
                              ? null
                              : () => _submit(quotation: true),
                          icon: const Icon(Icons.request_quote_outlined),
                          label: const Text('저장 후 견적서 작성'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _submit({
    bool attachments = false,
    bool quotation = false,
  }) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final invalid = _formKey.currentState!.validateGranularly();
    setState(() => _invalidFields = invalid);
    if (invalid.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goTo(invalid.first.context);
      });
      return;
    }
    final closed = _stores
        .where((s) => s.id == _storeId && s.isClosed)
        .firstOrNull;
    if (closed != null &&
        !await ConfirmDialog.show(
          context,
          title: '폐점 매장',
          message: '${closed.name}은(는) 폐점 매장입니다. 대응 기록을 저장하시겠습니까?',
          confirmLabel: '저장',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final repo = context.read<ServiceRepository>();
    final causes = _causes
        .where((c) => c.categoryId != null && c.categoryId!.isNotEmpty)
        .map((c) => c.toJson())
        .toList();
    bool submitted = false;
    final ok = await runGuarded(context, () async {
      if (_isRental && await _rentalField.currentState?.validate() != true) {
        return;
      }
      if (!mounted) return;
      try {
        final ServiceTicket saved;
        if (_isEdit) {
          saved = await repo.update(widget.ticket!.id, {
            'store_id': _storeId,
            'work_type_id': _workTypeId,
            'fault_id': _faultId,
            'received_at': _receivedAt,
            'description': _description.text.trim(),
            'causes': causes,
            'responder_ids': _responders.toList(),
            'is_rental': _isRental,
            'rental_type_id': _isRental ? _rentalTypeId : null,
            'rental_serials': _isRental ? _rentalSerials : null,
            'rental_due_date': _isRental
                ? ServiceRepository.dateOnly(_rentalDueDate)
                : null,
            'rental_returned': _isRental && _rentalReturned,
            'rental_return_date': _isRental && _rentalReturned
                ? ServiceRepository.dateOnly(_rentalReturnDate)
                : null,
            'customer_id': _customerId,
            'customer_name': _customerId == null
                ? _nullIfBlank(_customerName.text)
                : null,
            'contact_phone': _nullIfBlank(_phone.text),
            'site_address': _nullIfBlank(_address.text),
            'product_name': _nullIfBlank(_product.text),
            'model_name': _nullIfBlank(_model.text),
            'serial_no': _nullIfBlank(_serial.text),
            'assignee_id': _assigneeId,
            'priority': _priority.value,
            'channel': _channel.value,
            'is_warranty': _isWarranty,
          });
        } else {
          saved = await repo.create(
            storeId: _storeId,
            workTypeId: _workTypeId,
            faultId: _faultId,
            receivedAt: _receivedAt,
            description: _description.text.trim(),
            causes: causes,
            responderIds: _responders.toList(),
            isRental: _isRental,
            rentalTypeId: _isRental ? _rentalTypeId : null,
            rentalSerials: _isRental ? _rentalSerials : null,
            rentalDueDate: _isRental ? _rentalDueDate : null,
            rentalReturned: _isRental && _rentalReturned,
            rentalReturnDate: _isRental && _rentalReturned
                ? _rentalReturnDate
                : null,
            customerId: _customerId,
            customerName: _customerId == null
                ? _nullIfBlank(_customerName.text)
                : null,
            contactPhone: _nullIfBlank(_phone.text),
            siteAddress: _nullIfBlank(_address.text),
            productName: _nullIfBlank(_product.text),
            modelName: _nullIfBlank(_model.text),
            serialNo: _nullIfBlank(_serial.text),
            assigneeId: _assigneeId,
            priority: _priority,
            channel: _channel,
            isWarranty: _isWarranty,
          );
        }
        if (!mounted) return;
        AppSnack.saved(
          context,
          label:
              '${saved.displayNo}${saved.notices.isEmpty ? '' : ' · ${saved.notices.join(' / ')}'}',
          detail: () => ServiceDetailPage(ticketId: saved.id),
        );
        submitted = true;
        if (mounted && quotation) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QuotationPage(ticketId: saved.id),
            ),
          );
        }
        if (mounted && attachments) {
          await FormAttachmentsPage.open(context, 'service_ticket', saved.id);
        }
      } on ApiException catch (error) {
        if (error.code != 'RENTAL_SERIAL_UNKNOWN') rethrow;
        _rentalField.currentState?.markUnknown();
        _rentalField.currentState?.showRegistrationHint();
      }
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && submitted) Navigator.of(context).pop(true);
  }

  static String? _nullIfBlank(String v) => v.trim().isEmpty ? null : v.trim();
}

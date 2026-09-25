import 'package:flutter/material.dart';

import '../theme.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, this.actions = const [],
    required this.child, this.padding = const EdgeInsets.all(AppSpace.lg)});
  final String title;
  final List<Widget> actions;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    assert(actions.length <= 2);
    return Card(child: Padding(
    padding: padding,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, constraints) => constraints.maxWidth < 500 && actions.isNotEmpty
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Wrap(alignment: WrapAlignment.end, spacing: AppSpace.sm, children: actions),
          ])
        : Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ...actions,
          ])),
      const SizedBox(height: AppSpace.md),
      child,
    ]),
  ));
  }
}

/// Place inside a scroll view, or wrap a bounded list/table with this widget.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Padding(
        padding: EdgeInsets.all(AppTheme.isWide(context) ? AppSpace.xl : AppSpace.lg),
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );
}

class FormGap extends SizedBox {
  const FormGap({super.key}) : super(height: AppSpace.md);
}

/// Used inside a Scaffold body so resizeToAvoidBottomInset keeps it above the keyboard.
class FormActions extends StatelessWidget {
  const FormActions({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(top: false, child: Padding(
    padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.lg),
    child: SizedBox(width: double.infinity, child: child),
  ));
}

class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      for (final child in children) ...[const FormGap(), child],
    ],
  );
}

import 'package:flutter/material.dart';

import '../theme.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, this.actions = const [],
    required this.child, this.padding = const EdgeInsets.all(AppSpace.lg)})
      : assert(actions.length <= 2);
  final String title;
  final List<Widget> actions;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: padding,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
        ...actions,
      ]),
      const SizedBox(height: AppSpace.md),
      child,
    ]),
  ));
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

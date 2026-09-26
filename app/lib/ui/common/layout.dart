import 'package:flutter/material.dart';

import '../theme.dart';

/// A vertical card group with spacing only between its children.
class CardStack extends StatelessWidget {
  const CardStack({
    super.key,
    required this.children,
    this.spacing = AppSpace.md,
  });
  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) SizedBox(height: spacing),
        children[i],
      ],
    ],
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.actions = const [],
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.lg),
  });
  final String title;
  final List<Widget> actions;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    assert(actions.length <= 2);
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) =>
                  constraints.maxWidth < 500 && actions.isNotEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Wrap(
                          runSpacing: 12,
                          alignment: WrapAlignment.end,
                          spacing: AppSpace.sm,
                          children: actions,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        ...actions,
                      ],
                    ),
            ),
            const SizedBox(height: AppSpace.md),
            child,
          ],
        ),
      ),
    );
  }
}

/// Place inside a scroll view, or wrap a bounded list/table with this widget.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Padding(
        padding:
            padding ??
            EdgeInsets.all(
              AppTheme.isWide(context) ? AppSpace.xl : AppSpace.lg,
            ),
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );
}

/// Floating outline labels paint above the field's layout box. Keep that
/// space inside any scroll clip, scaled with the user's text size.
EdgeInsets fieldLabelInsets(BuildContext context) =>
    EdgeInsets.only(top: MediaQuery.textScalerOf(context).scale(AppSpace.sm));

class FormGap extends SizedBox {
  const FormGap({super.key}) : super(height: AppSpace.lg);
}

/// Shared vertical form rhythm; padding keeps floating labels inside scroll clips.
class FormFields extends StatelessWidget {
  const FormFields({
    super.key,
    required this.children,
    this.mainAxisSize = MainAxisSize.min,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });
  final List<Widget> children;
  final MainAxisSize mainAxisSize;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) => Padding(
    padding: fieldLabelInsets(context),
    child: Column(
      mainAxisSize: mainAxisSize,
      crossAxisAlignment: crossAxisAlignment,
      spacing: AppSpace.lg,
      children: children,
    ),
  );
}

/// Scrollable standalone form with consistent field/action gaps.
class FormListView extends StatelessWidget {
  const FormListView({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.only(
      top: MediaQuery.textScalerOf(context).scale(AppSpace.sm),
      bottom: AppSpace.lg,
    ),
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const FormGap(),
        children[i],
      ],
    ],
  );
}

/// Used inside a Scaffold body so resizeToAvoidBottomInset keeps it above the keyboard.
class FormActions extends StatelessWidget {
  const FormActions({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.lg),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
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
      const SizedBox(height: AppSpace.sm),
      FormFields(children: children),
    ],
  );
}

import 'package:flutter/material.dart';

import '../theme.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, this.icon = Icons.inbox_outlined,
    required this.message, this.action});
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(AppSpace.xl),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 44, color: AppColors.muted(context)),
      const SizedBox(height: AppSpace.md),
      Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
      if (action != null) ...[const SizedBox(height: AppSpace.lg), action!],
    ]),
  ));
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.cloud_off, message: message,
    action: onRetry == null ? null : OutlinedButton.icon(
      onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('다시 시도')),
  );
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message});
  final String? message;

  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(AppSpace.xl),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircularProgressIndicator(),
      if (message != null) ...[
        const SizedBox(height: AppSpace.lg),
        Text(message!, textAlign: TextAlign.center),
      ],
    ]),
  ));
}

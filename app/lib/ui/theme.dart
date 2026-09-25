import 'package:flutter/material.dart';

import 'common/states.dart';

/// Shared spacing and shape tokens (logical pixels).
abstract final class AppSpace {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

abstract final class AppRadius {
  static const sm = 8.0, md = 12.0, lg = 16.0;
}

/// Resolve status foregrounds against the current surface, including dark mode.
abstract final class AppColors {
  static Color success(BuildContext context) => _tone(context, const Color(0xFF146C43), const Color(0xFF75DBA5));
  static Color warning(BuildContext context) => _tone(context, const Color(0xFF805500), const Color(0xFFFFD574));
  static Color danger(BuildContext context) => Theme.of(context).colorScheme.error;
  static Color info(BuildContext context) => _tone(context, const Color(0xFF175DA8), const Color(0xFFA2C9FF));
  static Color muted(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;
  static Color _tone(BuildContext context, Color light, Color dark) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  // Retain server-defined hues while ensuring readable status text.
  static Color readable(BuildContext context, Color color) {
    final surface = Theme.of(context).colorScheme.surface;
    final target = Theme.of(context).colorScheme.onSurface;
    for (var step = 0; step <= 20; step++) {
      final candidate = Color.lerp(color, target, step / 20)!;
      final background = Color.alphaBlend(candidate.withValues(alpha: 0.14), surface);
      final a = candidate.computeLuminance(), b = background.computeLuminance();
      if ((a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05)) >= 4.5) return candidate;
    }
    return target;
  }
}

/// One theme for phone and desktop.
///
/// Desktop windows are wide, so the layout code keys off [isWide] rather than
/// off the platform: an Android tablet in landscape should get the same
/// two-pane treatment as a Windows window.
class AppTheme {
  static const seed = Color(0xFF3B82F6);

  /// Above this width the shell uses a side rail and two-pane detail views.
  static const wideBreakpoint = 900.0;

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 22, height: 1.4, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5),
        labelSmall: TextStyle(fontSize: 12, height: 1.4),
      ),
      dataTableTheme: DataTableThemeData(
        dataTextStyle: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurface),
        dividerThickness: 1,
        dataRowMinHeight: 44,
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(44, 44))),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        helperMaxLines: 2,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        side: BorderSide.none,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
    );
  }
}

/// Small coloured status pill used across every module list.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.readable(context, this.color ?? AppColors.muted(context));
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width empty / error / loading placeholder so every list looks alike.
class StatePlaceholder extends StatelessWidget {
  const StatePlaceholder({
    super.key,
    required this.icon,
    required this.message,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final text = detail == null ? message : '$message\n$detail';
    return EmptyState(
      icon: icon,
      message: text,
      action: onRetry == null ? null : OutlinedButton.icon(
        onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('다시 시도')),
    );
  }
}

/// Labelled number tile for dashboards.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.color,
    this.icon,
    this.onTap,
  });

  final String label;
  final String value;
  final String? hint;
  final Color? color;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: accent),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
              ),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(
                  hint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

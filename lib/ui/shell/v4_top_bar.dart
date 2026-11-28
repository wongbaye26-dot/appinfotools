import 'package:apk_info_tool/gen/strings.g.dart';
import 'package:apk_info_tool/models/analysis/package_analysis_result.dart';
import 'package:apk_info_tool/providers/info_page_provider.dart';
import 'package:apk_info_tool/theme/v4_theme.dart';
import 'package:apk_info_tool/ui/shell/v4_command_palette.dart';
import 'package:apk_info_tool/widgets/app_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// V4 top command bar.
///
/// It intentionally contains only ambient information: where you are, what is
/// loaded, and which version is running. Page-specific actions remain in each
/// page's `PageHeader`, so there is one place to find "what can I do here".
class V4TopBar extends ConsumerWidget {
  final String selectedId;

  const V4TopBar({super.key, required this.selectedId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fileState = ref.watch(currentFileStateProvider);
    final parsing = ref.watch(isParsingProvider);

    final label = switch (selectedId) {
      'overview' => t.nav.overview,
      'analysis' => t.nav.analysis,
      'history' => t.nav.history,
      'install' => t.nav.install,
      'diff' => t.nav.diff,
      'settings' => t.nav.settings,
      _ => t.nav.overview,
    };

    return SizedBox(
      height: 52,
      child: Row(
        children: [
          Text(
            'WORKSPACE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
              letterSpacing: 1.8,
              fontSize: 8,
              fontFamily: 'monospace',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Text(
              '/',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                fontSize: 9,
              ),
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface,
              letterSpacing: 1.2,
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
          if (selectedId == 'analysis' &&
              fileState.platform != PackagePlatform.unknown) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Text(
                '/',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                  fontSize: 9,
                ),
              ),
            ),
            Text(
              fileState.platform == PackagePlatform.ios ? 'IOS' : 'ANDROID',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 1.2,
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ],
          const SizedBox(width: 20),
          if (MediaQuery.sizeOf(context).width >= 1040)
            Expanded(
              child: Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: _SearchButton(
                    onTap: () => showV4CommandPalette(context, ref),
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          if (MediaQuery.sizeOf(context).width < 1040)
            const SizedBox(width: 12),
          _StatePill(
            selectedId: selectedId,
            filePath: fileState.filePath,
            parsing: parsing,
          ),
          const SizedBox(width: 12),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: AppLogo(size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SearchButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.shell.search_hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                'K',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  fontFamily: 'monospace',
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  final String selectedId;
  final String? filePath;
  final bool parsing;

  const _StatePill({
    required this.selectedId,
    required this.filePath,
    required this.parsing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    late final String label;
    late final Color color;
    late final Color background;

    if (selectedId == 'settings') {
      label = 'LOCAL-FIRST';
      color = V4Colors.mint;
      background = V4Colors.mint.withValues(alpha: 0.08);
    } else if (selectedId == 'diff') {
      label = 'FIELD DIFF';
      color = V4Colors.blue;
      background = V4Colors.blue.withValues(alpha: 0.08);
    } else if (selectedId == 'install') {
      label = 'DEVICE / ADB';
      color = V4Colors.amber;
      background = V4Colors.amber.withValues(alpha: 0.08);
    } else if (parsing) {
      label = 'PARSING';
      color = V4Colors.amber;
      background = V4Colors.amber.withValues(alpha: 0.08);
    } else if (filePath == null) {
      label = 'NO TARGET / IDLE';
      color = scheme.onSurfaceVariant;
      background = scheme.surfaceContainerLow;
    } else {
      label = 'TARGET LOADED';
      color = V4Colors.mint;
      background = V4Colors.mint.withValues(alpha: 0.08);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontSize: 7.5,
              letterSpacing: 0.7,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A very light dot grid behind the floating shell.
class V4DotGridPainter extends CustomPainter {
  final Color color;

  const V4DotGridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const gap = 22.0;
    for (var y = 0.0; y < size.height; y += gap) {
      for (var x = 0.0; x < size.width; x += gap) {
        canvas.drawCircle(Offset(x, y), 0.7, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant V4DotGridPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

import 'package:flutter/material.dart';
import '../../../../models/topic.dart';

class PostSegmentFrame extends StatelessWidget {
  final Post post;
  final bool highlight;
  final Widget child;
  final bool showTopDateSeparator;
  final String? topDateSeparatorLabel;
  final bool showBottomDateSeparator;
  final String? bottomDateSeparatorLabel;
  final bool showDivider;
  final bool showBottomBorder;
  final BoxConstraints? constraints;

  const PostSegmentFrame({
    super.key,
    required this.post,
    required this.highlight,
    required this.child,
    this.showTopDateSeparator = false,
    this.topDateSeparatorLabel,
    this.showBottomDateSeparator = false,
    this.bottomDateSeparatorLabel,
    this.showDivider = false,
    this.showBottomBorder = true,
    this.constraints,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targetColor = buildPostTargetColor(theme, post, highlight);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.5);

    return RepaintBoundary(
      child: Opacity(
        opacity: post.isDeleted ? 0.6 : 1.0,
        child: Container(
          constraints: constraints,
          decoration: BoxDecoration(
            color: targetColor,
            border: Border(
              bottom: showBottomBorder
                  ? BorderSide(color: borderColor, width: 0.5)
                  : BorderSide.none,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showDivider)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                      child: Text(
                        '上次看到这里',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  child,
                ],
              ),
              if (showTopDateSeparator && topDateSeparatorLabel != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: FractionalTranslation(
                    translation: const Offset(0, -0.5),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                        color: targetColor,
                        child: Text(
                          topDateSeparatorLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (showBottomDateSeparator && bottomDateSeparatorLabel != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: FractionalTranslation(
                    translation: const Offset(0, 0.5),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                        color: targetColor,
                        child: Text(
                          bottomDateSeparatorLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Color buildPostTargetColor(ThemeData theme, Post post, bool highlight) {
  final backgroundColor = theme.colorScheme.surface;
  final highlightColor = theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5);
  return highlight
      ? Color.alphaBlend(highlightColor, backgroundColor)
      : post.isDeleted
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.15)
          : backgroundColor;
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../../services/discourse_cache_manager.dart';

import 'builders/video_builder.dart';
import 'image_utils.dart';
import 'lazy_image.dart';
import 'selectable_adapter.dart';

/// 自定义 WidgetFactory，仅用于接管图片渲染
class DiscourseWidgetFactory extends WidgetFactory {
  final BuildContext context;
  final GalleryInfo? galleryInfo;

  /// 获取画廊图片列表（原图 URL）
  List<String> get galleryImages => galleryInfo?.images ?? [];

  /// SVG 内容缓存：避免每次 build 都重新执行 getSingleFile() 的 SQLite 查询
  final Map<String, _SvgCacheEntry> _svgCache = {};
  /// 正在加载中的 SVG URL，避免并发重复加载
  final Set<String> _svgLoading = {};

  DiscourseWidgetFactory({
    required this.context,
    this.galleryInfo,
  });

  @override
  Widget? buildListMarker(
    BuildTree tree,
    InheritedProperties resolved,
    String listStyleType,
    int index,
  ) {
    final markerText = getListMarkerText(listStyleType, index);
    // 有序列表：使用等宽数字，避免 "1" 比其他数字窄导致的对齐问题
    if (markerText.isNotEmpty) {
      return Text(
        markerText,
        style: resolved.prepareTextStyle().copyWith(
          // 启用表格数字特性，让所有数字宽度一致
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }
    return super.buildListMarker(tree, resolved, listStyleType, index);
  }

  @override
  Widget? buildImage(BuildTree tree, ImageMetadata data) {
    final url = data.sources.firstOrNull?.url;
    if (url == null) return super.buildImage(tree, data);

    // 尝试获取宽高信息
    final double? width = data.sources.firstOrNull?.width;
    final double? height = data.sources.firstOrNull?.height;

    // 检查是否是显式的 emoji class
    final bool isEmoji = tree.element.classes.contains('emoji');

    // 获取 emoji title（用于 SelectableAdapter，使 emoji 可被选中）
    final String? emojiTitle = isEmoji
        ? (tree.element.attributes['title'] ?? tree.element.attributes['alt'])
        : null;

    // 普通 URL：直接构建 widget，无需 FutureBuilder
    if (!DiscourseImageUtils.isUploadUrl(url)) {
      return _buildImageWidget(url, url, width, height, isEmoji, emojiTitle: emojiTitle);
    }

    // upload:// 短链接：检查缓存
    if (DiscourseImageUtils.isUploadUrlCached(url)) {
      final resolvedUrl = DiscourseImageUtils.getCachedUploadUrl(url);
      if (resolvedUrl != null) {
        return _buildImageWidget(resolvedUrl, url, width, height, isEmoji, emojiTitle: emojiTitle);
      }
      // 解析失败的 URL，显示错误图标
      return Icon(
        Icons.broken_image,
        color: Theme.of(context).colorScheme.outline,
        size: 24,
      );
    }

    // upload:// 短链接首次加载：使用 FutureBuilder 解析
    return FutureBuilder<String?>(
      future: DiscourseImageUtils.resolveUploadUrl(url),
      builder: (context, snapshot) {

        // 解析失败
        if (snapshot.connectionState == ConnectionState.done && snapshot.data == null) {
          return Icon(
            Icons.broken_image,
            color: Theme.of(context).colorScheme.outline,
            size: 24,
          );
        }

        return _buildImageWidget(snapshot.data, url, width, height, isEmoji, emojiTitle: emojiTitle);
      },
    );
  }

  /// 构建图片 widget（从缓存或 FutureBuilder 调用）
  Widget _buildImageWidget(String? resolvedUrl, String originalUrl, double? width, double? height, bool isEmoji, {String? emojiTitle}) {
    // 检查是否是 SVG（处理带查询参数的 URL）
    final isSvg = _isSvgUrl(resolvedUrl) || _isSvgUrl(originalUrl);

    if (isSvg && resolvedUrl != null) {
      return _buildSvgWidget(resolvedUrl, width, height, isEmoji);
    }

    // 使用自定义的鉴权 ImageProvider（即使在 waiting 状态也可以构建）
    final imageProvider = resolvedUrl != null
        ? discourseImageProvider(resolvedUrl)
        : null;

    // 检查是否在画廊列表中（使用 findIndex 支持缩略图→原图的多种 URL 变体匹配）
    final int galleryIndex = resolvedUrl != null ? (galleryInfo?.findIndex(resolvedUrl) ?? -1) : -1;
    final bool isGalleryImage = galleryIndex != -1;

    // 生成唯一 Tag
    // 画廊图片使用确定性 tag（基于画廊内容和索引），以便切换图片后 Hero 动画能正确返回
    // 非画廊图片使用 UniqueKey 避免冲突
    final String heroTag;
    if (isGalleryImage) {
      final int galleryHash = Object.hashAll(galleryImages);
      heroTag = "gallery_${galleryHash}_$galleryIndex";
    } else {
      heroTag = "${resolvedUrl ?? originalUrl}_${UniqueKey().toString()}";
    }

    return Builder(
      builder: (context) {
        // 计算合适的 Emoji 尺寸
        final double emojiSize = DefaultTextStyle.of(context).style.fontSize ?? 16.0;
        final double displaySize = emojiSize * 1.2;

        // 如果不是画廊图片（通常是 Emoji 或预览中的 upload:// 图片）
        if (!isGalleryImage || isEmoji) {
           Widget imageWidget = imageProvider != null
               ? Image(
                   image: imageProvider,
                   fit: BoxFit.contain,
                   // Emoji 使用固定尺寸，普通图片让其自适应（由外层约束控制）
                   width: isEmoji ? displaySize : null,
                   height: isEmoji ? displaySize : null,
                   loadingBuilder: (context, child, loadingProgress) {
                     if (loadingProgress == null) return child;
                     return SizedBox(
                       width: isEmoji ? displaySize : width ?? 24,
                       height: isEmoji ? displaySize : height ?? 24,
                       child: Center(
                         child: SizedBox(
                           width: 12,
                           height: 12,
                           child: CircularProgressIndicator(
                             strokeWidth: 1.5,
                             value: loadingProgress.expectedTotalBytes != null
                                 ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                                 : null,
                           ),
                         ),
                       ),
                     );
                   },
                   errorBuilder: (context, error, stackTrace) {
                     return Icon(
                       Icons.broken_image,
                       color: Theme.of(context).colorScheme.outline,
                       size: isEmoji ? displaySize : 24,
                     );
                   },
                 )
               : SizedBox(
                   width: isEmoji ? displaySize : width ?? 24,
                   height: isEmoji ? displaySize : height ?? 24,
                   child: const Center(
                     child: SizedBox(
                       width: 12,
                       height: 12,
                       child: CircularProgressIndicator(strokeWidth: 1.5),
                     ),
                   ),
                 );

           if (isEmoji) {
             Widget emojiWidget = Container(
               margin: const EdgeInsets.symmetric(horizontal: 2.0),
               child: imageWidget,
             );
             // 用 SelectableAdapter 包裹，使 emoji 参与文本选择
             if (emojiTitle != null && emojiTitle.isNotEmpty) {
               emojiWidget = SelectableAdapter(
                 selectedText: emojiTitle,
                 child: emojiWidget,
               );
             }
             return emojiWidget;
           }

           // 非画廊图片：与 Discourse 一致，不添加点击查看功能
           // 只有 lightbox 图片（画廊图片）才能点击打开查看器
           return imageWidget;
        }

        // 画廊图片处理
        Widget buildGalleryImage() {
          if (imageProvider == null) {
            // URL 解析中，显示占位符
            final screenWidth = MediaQuery.of(context).size.width;
            final double displayWidth = screenWidth - 32;
            final double displayHeight = width != null && height != null && height > 0
                ? displayWidth * (height / width)
                : 200.0;

            return Container(
              width: displayWidth,
              height: displayHeight,
              alignment: Alignment.center,
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha:0.2),
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }

          // 使用 LazyImage 懒加载
          return LazyImage(
            imageProvider: imageProvider,
            width: width,
            height: height,
            heroTag: heroTag,
            cacheKey: resolvedUrl, // 使用稳定的 URL 作为缓存 key
            onTap: () {
              final originalUrl = DiscourseImageUtils.getOriginalUrl(resolvedUrl!);
              final originalGalleryImages = galleryImages
                  .map((e) => DiscourseImageUtils.getOriginalUrl(e))
                  .toList();
              final heroTags = DiscourseImageUtils.generateGalleryHeroTags(galleryImages);

              DiscourseImageUtils.openViewer(
                context: context,
                imageUrl: originalUrl,
                heroTag: heroTag,
                galleryImages: originalGalleryImages,
                heroTags: heroTags,
                initialIndex: galleryIndex,
                thumbnailUrl: resolvedUrl,
                thumbnailUrls: galleryImages,
                filenames: galleryInfo?.filenames,
              );
            },
          );
        }

        return buildGalleryImage();
      }
    );
  }

  @override
  Widget? buildGestureDetector(
    BuildTree tree,
    Widget child,
    GestureRecognizer recognizer,
  ) {
    // 对 a.lightbox 不包裹手势，避免与内部图片的 GestureDetector 冲突
    // 图片的点击由 buildImage 中的 LazyImage/HeroImage 处理
    final element = tree.element;
    if (element.localName == 'a' &&
        element.classes.contains('lightbox')) {
      return child;
    }
    return super.buildGestureDetector(tree, child, recognizer);
  }



  @override
  Widget? buildVideoPlayer(
    BuildTree tree,
    String url, {
    required bool autoplay,
    required bool controls,
    double? height,
    required bool loop,
    String? posterUrl,
    double? width,
  }) {
    final dimensOk = height != null && height > 0 && width != null && width > 0;
    final poster = posterUrl != null
        ? buildImage(tree, ImageMetadata(sources: [ImageSource(posterUrl)]))
        : null;
    return DiscourseVideoPlayer(
      url,
      aspectRatio: dimensOk ? width / height : 16 / 9,
      autoResize: !dimensOk,
      autoplay: autoplay,
      controls: controls,
      errorBuilder: (context, _, error) =>
          onErrorBuilder(context, tree, error, url) ?? widget0,
      loadingBuilder: (context, _, child) =>
          onLoadingBuilder(context, tree, null, url) ?? widget0,
      loop: loop,
      poster: poster,
    );
  }

  /// 检查 URL 是否为 SVG（处理带查询参数的情况）
  bool _isSvgUrl(String? url) {
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.path.toLowerCase().endsWith('.svg');
  }

  /// 构建 SVG 图片 widget
  ///
  /// 使用内存缓存避免每次 build 都重新执行 getSingleFile() 的 SQLite 查询。
  /// 缓存和 DiscourseWidgetFactory 实例同生命周期（跟随 DiscourseHtmlContent State）。
  Widget _buildSvgWidget(String url, double? width, double? height, bool isEmoji) {
    return Builder(
      builder: (context) {
        final emojiSize = (DefaultTextStyle.of(context).style.fontSize ?? 16.0) * 1.2;

        // 命中缓存则直接渲染
        final cached = _svgCache[url];
        if (cached != null) {
          if (isEmoji) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2.0),
              child: SizedBox(
                width: emojiSize,
                height: emojiSize,
                child: SvgPicture.string(cached.content, fit: BoxFit.contain),
              ),
            );
          }
          return SvgPicture.string(
            cached.content,
            width: cached.width ?? width,
            height: cached.height ?? height,
            fit: BoxFit.contain,
          );
        }

        // 异步加载并缓存
        _loadSvg(url);

        // 占位
        final size = isEmoji ? emojiSize : (width ?? 24.0);
        return SizedBox(width: size, height: isEmoji ? emojiSize : (height ?? 24.0));
      },
    );
  }

  /// 异步加载 SVG 文件内容到缓存
  Future<void> _loadSvg(String url) async {
    if (_svgLoading.contains(url)) return;
    _svgLoading.add(url);

    try {
      final file = await DiscourseCacheManager().getSingleFile(url);
      var content = await file.readAsString();
      final svgWidth = _parseSvgDimension(content, 'width');
      final svgHeight = _parseSvgDimension(content, 'height');
      content = _fixSvgTextScale(content);

      _svgCache[url] = _SvgCacheEntry(content: content, width: svgWidth, height: svgHeight);
    } catch (_) {
      // 加载失败不缓存，下次重试
    } finally {
      _svgLoading.remove(url);
    }
  }

  /// 修复 SVG 中 text 元素的 scale 变换问题
  String _fixSvgTextScale(String svg) {
    // 匹配 font-size="110" 这样的大字体
    final fontSizeMatch = RegExp(r'font-size="(\d+)"').firstMatch(svg);
    if (fontSizeMatch == null) return svg;

    final fontSize = int.tryParse(fontSizeMatch.group(1)!) ?? 0;
    if (fontSize <= 20) return svg; // 正常字体大小，不需要修复

    // 查找 scale 变换
    final scaleMatch = RegExp(r'transform="scale\(\.(\d+)\)"').firstMatch(svg);
    if (scaleMatch == null) return svg;

    final scaleValue = double.tryParse('0.${scaleMatch.group(1)}') ?? 1.0;
    final newFontSize = (fontSize * scaleValue).round();

    // 替换字体大小并移除 scale 变换
    svg = svg.replaceAll('font-size="$fontSize"', 'font-size="$newFontSize"');
    svg = svg.replaceAll(RegExp(r' transform="scale\(\.\d+\)"'), '');

    // 修复 text 元素的坐标（也需要缩放）
    svg = svg.replaceAllMapped(RegExp(r'<text([^>]*) x="(\d+)"([^>]*) y="(\d+)"'), (m) {
      final x = ((int.tryParse(m.group(2)!) ?? 0) * scaleValue).round();
      final y = ((int.tryParse(m.group(4)!) ?? 0) * scaleValue).round();
      return '<text${m.group(1)} x="$x"${m.group(3)} y="$y"';
    });

    return svg;
  }

  /// 从 SVG 内容解析尺寸属性
  double? _parseSvgDimension(String svg, String attr) {
    final match = RegExp('$attr="(d+(?:.d+)?)"').firstMatch(svg);
    if (match != null) return double.tryParse(match.group(1)!);
    return null;
  }
}

/// SVG 内容缓存条目
class _SvgCacheEntry {
  final String content;
  final double? width;
  final double? height;

  const _SvgCacheEntry({required this.content, this.width, this.height});
}
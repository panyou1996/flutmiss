// ignore_for_file: invalid_use_of_protected_member

part of '../post_footer_section.dart';

extension _PostFooterBookmarkActions on _PostFooterSectionState {
  Future<void> _toggleBookmark() async {
    if (_isBookmarking) return;

    HapticFeedback.lightImpact();
    setState(() => _isBookmarking = true);

    try {
      if (_isBookmarked) {
        final bookmarkId = _bookmarkId ?? widget.post.bookmarkId;
        if (bookmarkId != null) {
          await _service.deleteBookmark(bookmarkId);
          if (mounted) {
            setState(() {
              _isBookmarked = false;
              _bookmarkId = null;
            });
            ToastService.showSuccess('已取消书签');
          }
        }
      } else {
        final bookmarkId = await _service.bookmarkPost(widget.post.id);
        if (mounted) {
          setState(() {
            _isBookmarked = true;
            _bookmarkId = bookmarkId;
          });
          ToastService.showSuccess('已添加书签');
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isBookmarking = false);
      }
    }
  }
}

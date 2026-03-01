part of '../post_footer_section.dart';

extension _PostFooterReplyActions on _PostFooterSectionState {
  Future<void> _loadReplies() async {
    if (_isLoadingRepliesNotifier.value) return;

    _isLoadingRepliesNotifier.value = true;
    try {
      final after = _replies.isNotEmpty ? _replies.last.postNumber : 1;
      final replies = await _service.getPostReplies(widget.post.id, after: after);
      if (mounted) {
        _replies.addAll(replies);
        _isLoadingRepliesNotifier.value = false;
      }
    } catch (_) {
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    }
  }

  Future<void> _toggleReplies() async {
    if (_showRepliesNotifier.value) {
      _showRepliesNotifier.value = false;
      return;
    }

    if (_replies.isNotEmpty) {
      _showRepliesNotifier.value = true;
      return;
    }

    if (_isLoadingRepliesNotifier.value) return;

    _isLoadingRepliesNotifier.value = true;
    try {
      final replies = await _service.getPostReplies(widget.post.id, after: 1);
      if (mounted) {
        _replies.addAll(replies);
        _isLoadingRepliesNotifier.value = false;
        _showRepliesNotifier.value = true;
      }
    } catch (_) {
      if (mounted) {
        _isLoadingRepliesNotifier.value = false;
      }
    }
  }
}

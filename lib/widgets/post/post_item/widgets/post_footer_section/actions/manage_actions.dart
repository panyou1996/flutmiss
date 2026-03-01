// ignore_for_file: invalid_use_of_protected_member

part of '../post_footer_section.dart';

extension _PostFooterManageActions on _PostFooterSectionState {
  Future<void> _toggleSolution() async {
    if (_isTogglingAnswer) return;

    HapticFeedback.lightImpact();
    setState(() => _isTogglingAnswer = true);

    try {
      if (_isAcceptedAnswer) {
        await _service.unacceptAnswer(widget.post.id);
        if (mounted) {
          setState(() => _isAcceptedAnswer = false);
          widget.onAcceptedAnswerChanged?.call(false);
          widget.onSolutionChanged?.call(widget.post.id, false);
          ToastService.showSuccess('已取消采纳');
        }
      } else {
        await _service.acceptAnswer(widget.post.id);
        if (mounted) {
          setState(() => _isAcceptedAnswer = true);
          widget.onAcceptedAnswerChanged?.call(true);
          widget.onSolutionChanged?.call(widget.post.id, true);
          ToastService.showSuccess('已采纳为解决方案');
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isTogglingAnswer = false);
      }
    }
  }

  Future<void> _deletePost() async {
    if (_isDeleting) return;
    HapticFeedback.lightImpact();
    setState(() => _isDeleting = true);

    try {
      await _service.deletePost(widget.post.id);
      if (mounted) {
        ToastService.showSuccess('已删除');
        widget.onRefreshPost?.call(widget.post.id);
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  Future<void> _recoverPost() async {
    if (_isDeleting) return;
    HapticFeedback.lightImpact();
    setState(() => _isDeleting = true);

    try {
      await _service.recoverPost(widget.post.id);
      if (mounted) {
        ToastService.showSuccess('已恢复');
        widget.onRefreshPost?.call(widget.post.id);
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }
}

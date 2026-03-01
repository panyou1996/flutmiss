// ignore_for_file: invalid_use_of_protected_member

part of '../post_footer_section.dart';

extension _PostFooterReactionActions on _PostFooterSectionState {
  void _syncReactionToProvider(List<PostReaction> reactions, PostReaction? currentUserReaction) {
    final params = TopicDetailParams(widget.topicId);

    try {
      ref
          .read(topicDetailProvider(params).notifier)
          .updatePostReaction(widget.post.id, reactions, currentUserReaction);
    } catch (_) {}
  }

  Future<void> _toggleLike() async {
    if (_isLiking) return;

    HapticFeedback.lightImpact();
    setState(() => _isLiking = true);

    try {
      final reactionId = _currentUserReaction?.id ?? 'heart';
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (!mounted) return;

      setState(() {
        _reactions = result['reactions'] as List<PostReaction>;
        _currentUserReaction = result['currentUserReaction'] as PostReaction?;
      });

      _syncReactionToProvider(_reactions, _currentUserReaction);
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLiking = false);
      }
    }
  }

  Future<void> _toggleReaction(String reactionId) async {
    try {
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (!mounted) return;

      setState(() {
        _reactions = result['reactions'] as List<PostReaction>;
        _currentUserReaction = result['currentUserReaction'] as PostReaction?;
      });

      _syncReactionToProvider(_reactions, _currentUserReaction);
    } catch (_) {}
  }

  void _showReactionPicker(BuildContext context, ThemeData theme) async {
    HapticFeedback.mediumImpact();

    final reactions = await _service.getEnabledReactions();
    if (!context.mounted || reactions.isEmpty) return;

    // ignore: use_build_context_synchronously
    PostReactionPicker.show(
      context: context,
      theme: theme,
      likeButtonKey: _likeButtonKey,
      reactions: reactions,
      currentUserReaction: _currentUserReaction,
      onReactionSelected: _toggleReaction,
    );
  }

  void _showReactionUsers(BuildContext context, {String? reactionId}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PostReactionUsersSheet(
        postId: widget.post.id,
        initialReactionId: reactionId,
      ),
    );
  }
}

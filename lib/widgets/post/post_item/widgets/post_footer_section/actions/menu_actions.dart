part of '../post_footer_section.dart';

extension _PostFooterMenuActions on _PostFooterSectionState {
  Future<void> _sharePost() async {
    final url = '${AppConstants.baseUrl}/t/${widget.topicId}/${widget.post.postNumber}';
    await SharePlus.instance.share(ShareParams(text: url));
  }

  void _showFlagDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PostFlagSheet(
        postId: widget.post.id,
        postUsername: widget.post.username,
        service: _service,
        onSuccess: () => ToastService.showSuccess('举报已提交'),
      ),
    );
  }

  void _showDeleteConfirmDialog(BuildContext context, ThemeData theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除回复'),
        content: const Text('确定要删除这条回复吗？此操作可以撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deletePost();
            },
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showMoreMenu(BuildContext context, ThemeData theme) {
    final isGuest = ref.read(currentUserProvider).value == null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.post.canEdit && widget.onEdit != null)
                ListTile(
                  leading: Icon(Icons.edit_outlined, color: theme.colorScheme.primary),
                  title: Text('编辑', style: TextStyle(color: theme.colorScheme.primary)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onEdit!();
                  },
                ),
              ListTile(
                leading: Icon(Icons.share_outlined, color: theme.colorScheme.onSurface),
                title: const Text('分享链接'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sharePost();
                },
              ),
              if (widget.onShareAsImage != null)
                ListTile(
                  leading: Icon(Icons.image_outlined, color: theme.colorScheme.onSurface),
                  title: const Text('生成分享图片'),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onShareAsImage!();
                  },
                ),
              if (!isGuest)
                Builder(
                  builder: (context) {
                    final currentUser = ref.read(currentUserProvider).value;
                    final isOwnPost =
                        currentUser != null && currentUser.username == widget.post.username;
                    final credentials = ref.read(ldcRewardCredentialsProvider).value;
                    if (isOwnPost || widget.post.userId == null || credentials == null) {
                      return const SizedBox.shrink();
                    }
                    return ListTile(
                      leading: Icon(
                        Icons.volunteer_activism_rounded,
                        color: theme.colorScheme.onSurface,
                      ),
                      title: const Text('打赏 LDC'),
                      onTap: () {
                        Navigator.pop(ctx);
                        showLdcRewardSheet(
                          context,
                          RewardTargetInfo(
                            userId: widget.post.userId!,
                            username: widget.post.username,
                            name: widget.post.name,
                            avatarUrl: widget.post.getAvatarUrl(),
                            topicId: widget.topicId,
                            postId: widget.post.id,
                          ),
                        );
                      },
                    );
                  },
                ),
              if (!isGuest && (widget.post.canAcceptAnswer || widget.post.canUnacceptAnswer))
                ListTile(
                  leading: Icon(
                    _isAcceptedAnswer ? Icons.check_box : Icons.check_box_outline_blank,
                    color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.onSurface,
                  ),
                  title: Text(
                    _isAcceptedAnswer ? '取消采纳' : '采纳为解决方案',
                    style: TextStyle(
                      color: _isAcceptedAnswer ? Colors.green : theme.colorScheme.onSurface,
                    ),
                  ),
                  onTap: _isTogglingAnswer
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _toggleSolution();
                        },
                ),
              if (!isGuest)
                ListTile(
                  leading: Icon(
                    _isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: _isBookmarked
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                  title: Text(_isBookmarked ? '取消书签' : '添加书签'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleBookmark();
                  },
                ),
              if (!isGuest)
                ListTile(
                  leading: Icon(Icons.flag_outlined, color: theme.colorScheme.error),
                  title: Text('举报', style: TextStyle(color: theme.colorScheme.error)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showFlagDialog(context);
                  },
                ),
              if (!isGuest && widget.post.canRecover)
                ListTile(
                  leading: Icon(Icons.restore, color: theme.colorScheme.primary),
                  title: Text('恢复', style: TextStyle(color: theme.colorScheme.primary)),
                  onTap: _isDeleting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _recoverPost();
                        },
                ),
              if (!isGuest && widget.post.canDelete && !widget.post.isDeleted)
                ListTile(
                  leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                  title: Text('删除', style: TextStyle(color: theme.colorScheme.error)),
                  onTap: _isDeleting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _showDeleteConfirmDialog(context, theme);
                        },
                ),
              const SizedBox(height: 8),
              ListTile(
                title: Text(
                  '取消',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

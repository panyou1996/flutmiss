part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 滚动和导航相关方法
extension _ScrollActions on _TopicDetailPageState {
  void _onScroll() {
    if (_isRefreshing) return;

    _scheduleCheckTitleVisibility();
    _controller.handleScroll();

    final params = _params;
    final detailAsync = ref.read(topicDetailProvider(params));

    if (detailAsync.isLoading) return;

    final notifier = ref.read(topicDetailProvider(params).notifier);

    if (_controller.shouldLoadPrevious(notifier.hasMoreBefore, notifier.isLoadingPrevious)) {
      notifier.loadPrevious();
    }

    if (_controller.shouldLoadMore(notifier.hasMoreAfter, notifier.isLoadingMore)) {
      notifier.loadMore();
    }
  }

  void _updateStreamIndexForPostNumber(int postNumber) {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final stream = detail.postStream.stream;

    final post = posts.firstWhere(
      (p) => p.postNumber == postNumber,
      orElse: () => posts.first,
    );

    final streamIndex = stream.indexOf(post.id);
    if (streamIndex != -1) {
      final newIndex = streamIndex + 1;
      _controller.updateStreamIndex(newIndex);
    }
  }

  void _updateReadPostNumbers(Set<int> readPostNumbers) {
    if (setEquals(_lastReadPostNumbers, readPostNumbers)) return;
    _lastReadPostNumbers = readPostNumbers;
    _controller.setReadPostNumbers(readPostNumbers);
  }

  void _updateVisiblePosts(Set<int> visiblePostNumbers) {
    _controller.updateVisiblePosts(visiblePostNumbers);
  }

  Future<void> _scrollToTop() async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;

    if (detail != null && detail.postStream.posts.isNotEmpty &&
        detail.postStream.posts.first.postNumber == 1) {
      _controller.scrollToTop();
      return;
    }

    debugPrint('[TopicDetail] First post not loaded, reloading from post 1');
    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = false;

    final notifier = ref.read(topicDetailProvider(params).notifier);
    await notifier.reloadWithPostNumber(1);
  }

  Future<void> _scrollToPost(int postNumber) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.postNumber == postNumber);
    final notifier = ref.read(topicDetailProvider(params).notifier);

    if (postIndex == -1) {
      debugPrint('[TopicDetail] Post $postNumber not in list, reloading with new postNumber');
      _controller.prepareJumpToPost(postNumber);
      _controller.skipNextJumpHighlight = false;

      if (notifier.isSummaryMode || notifier.isAuthorOnlyMode) {
        await _reloadWithFilterFallback(postNumber: postNumber);
      } else {
        await notifier.reloadWithPostNumber(postNumber);
      }
      return;
    }

    // 计算距离，如果距离过大直接使用本地跳转
    bool forceLocalJump = false;
    final stream = detail.postStream.stream;
    final currentVisibleIndex = _controller.currentVisibleStreamIndex;

    final targetPost = posts.firstWhere((p) => p.postNumber == postNumber, orElse: () => posts.first);
    final targetStreamIndex = stream.indexOf(targetPost.id);

    if (currentVisibleIndex != -1 && targetStreamIndex != -1) {
      if ((targetStreamIndex - currentVisibleIndex).abs() > 15) {
        forceLocalJump = true;
      }
    }

    if (!forceLocalJump && _controller.isPostRendered(postIndex)) {
      await _controller.scrollToPost(postNumber, posts);
    } else {
      int? anchorPostNumber;
      if (posts.length - 1 - postIndex < 20) {
        final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
        anchorPostNumber = posts[safeIndex].postNumber;
      }
      _controller.jumpToPostLocally(postNumber, anchorPostNumber: anchorPostNumber);
      if (mounted) setState(() {});
    }
    _controller.triggerHighlight(postNumber);
  }

  Future<void> _scrollToPostById(int postId) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final posts = detail.postStream.posts;
    final postIndex = posts.indexWhere((p) => p.id == postId);

    if (postIndex != -1) {
      final post = posts[postIndex];

      bool forceLocalJump = false;
      final currentVisibleIndex = _controller.currentVisibleStreamIndex;
      final targetStreamIndex = detail.postStream.stream.indexOf(postId);

      if (currentVisibleIndex != -1 && targetStreamIndex != -1) {
        if ((targetStreamIndex - currentVisibleIndex).abs() > 15) {
          forceLocalJump = true;
        }
      }

      if (!forceLocalJump && _controller.isPostRendered(postIndex)) {
        await _controller.scrollController.scrollToIndex(
          _controller.scrollIndexForPostIndex(postIndex),
          preferPosition: AutoScrollPosition.begin,
          duration: const Duration(milliseconds: 1),
        );
      } else {
        int? anchorPostNumber;
        if (posts.length - 1 - postIndex < 20) {
          final safeIndex = (posts.length - 20).clamp(0, posts.length - 1);
          anchorPostNumber = posts[safeIndex].postNumber;
        }

        _controller.jumpToPostLocally(post.postNumber, anchorPostNumber: anchorPostNumber);
        if (mounted) setState(() {});
      }
      _controller.triggerHighlight(post.postNumber);
      return;
    }

    debugPrint('[TopicDetail] Post ID $postId not in loaded posts, fetching post info...');

    try {
      final service = DiscourseService();
      final postStream = await service.getPosts(widget.topicId, [postId]);

      if (postStream.posts.isEmpty) {
        debugPrint('[TopicDetail] Failed to fetch post $postId');
        return;
      }

      final targetPost = postStream.posts.first;
      final realPostNumber = targetPost.postNumber;
      debugPrint('[TopicDetail] Got real post_number: $realPostNumber for post ID $postId');

      _controller.prepareJumpToPost(realPostNumber);
      _controller.skipNextJumpHighlight = false;

      final notifier = ref.read(topicDetailProvider(params).notifier);

      if (notifier.isSummaryMode || notifier.isAuthorOnlyMode) {
        await _reloadWithFilterFallback(postNumber: realPostNumber, postId: postId);
      } else {
        await notifier.reloadWithPostNumber(realPostNumber);
      }
    } catch (e) {
      debugPrint('[TopicDetail] Error fetching post $postId: $e');
    }
  }

  void _scrollToInitialPosition(List<Post> posts, int? dividerPostIndex) {
    _doInitialScroll(posts, dividerPostIndex, retryCount: 0);
  }

  void _doInitialScroll(List<Post> posts, int? dividerPostIndex, {required int retryCount}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      if (retryCount == 0) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      if (!mounted) return;

      if (!_controller.scrollController.hasClients) {
        if (retryCount < 5) {
          await Future.delayed(const Duration(milliseconds: 50));
          if (mounted) {
            _doInitialScroll(posts, dividerPostIndex, retryCount: retryCount + 1);
          }
          return;
        } else {
          if (mounted && !_controller.isPositioned) {
            _controller.markPositioned();
          }
          return;
        }
      }

      try {
        int? targetPostIndex;
        bool shouldHighlight = false;
        final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;
        final jumpTarget = _controller.jumpTargetPostNumber;
        final currentPostNumber = _controller.currentPostNumber;

        if (jumpTarget != null) {
          for (int i = 0; i < posts.length; i++) {
            if (posts[i].postNumber >= jumpTarget) {
              targetPostIndex = i;
              shouldHighlight = !_controller.skipNextJumpHighlight;
              break;
            }
          }
        } else if (dividerPostIndex != null && dividerPostIndex < posts.length) {
          targetPostIndex = dividerPostIndex;
          shouldHighlight = true;
        } else if (currentPostNumber != null && currentPostNumber > 0) {
          for (int i = 0; i < posts.length; i++) {
            if (posts[i].postNumber >= currentPostNumber) {
              targetPostIndex = i;
              shouldHighlight = true;
              break;
            }
          }
        }

        if (targetPostIndex != null) {
          if (hasFirstPost && targetPostIndex == 0) {
            await _controller.scrollController.animateTo(
              _controller.scrollController.position.minScrollExtent,
              duration: const Duration(milliseconds: 1),
              curve: Curves.linear,
            );
          } else {
            await _controller.scrollController.scrollToIndex(
              _controller.scrollIndexForPostIndex(targetPostIndex),
              preferPosition: AutoScrollPosition.begin,
              duration: const Duration(milliseconds: 1),
            );
          }

          _controller.clearJumpTarget();
          _controller.skipNextJumpHighlight = false;

          if (shouldHighlight) {
            _controller.pendingHighlightPostNumber = posts[targetPostIndex].postNumber;
          }
        }
      } catch (e, stack) {
        debugPrint('[TopicDetail] Scroll error: $e\n$stack');
      } finally {
        if (mounted && !_controller.isPositioned) {
          _controller.markPositioned();
          if (_controller.pendingHighlightPostNumber != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _controller.consumePendingHighlight();
              }
            });
          }
        }
      }
    });
  }
}

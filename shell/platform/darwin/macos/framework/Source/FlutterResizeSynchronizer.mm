// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterResizeSynchronizer.h"

#include <mutex>

@interface FlutterResizeSynchronizer () {
  // Counter to detect stale callbacks.
  uint32_t _cookie;

  std::mutex _mutex;

  // Used to block [beginResize:].
  std::condition_variable _condBlockBeginResize;
  // Used to block [requestCommit].
  std::condition_variable _condBlockRequestCommit;

  // If NO, requestCommit calls are ignored until shouldEnsureSurfaceForSize is called with
  // proper size.
  BOOL _acceptingCommit;

  // Waiting for resize to finish.
  BOOL _waiting;

  // RequestCommit was called and [delegate commit:] must be performed on platform thread.
  BOOL _pendingCommit;

  // Target size for resizing.
  CGSize _newSize;

  __weak id<FlutterResizeSynchronizerDelegate> _delegate;
}
@end

@implementation FlutterResizeSynchronizer

- (instancetype)initWithDelegate:(id<FlutterResizeSynchronizerDelegate>)delegate {
  if (self = [super init]) {
    _acceptingCommit = YES;
    _delegate = delegate;
  }
  return self;
}

- (void)beginResize:(CGSize)size notify:(dispatch_block_t)notify {
  std::unique_lock<std::mutex> lock(_mutex);
  if (!_delegate) {
    return;
  }

  ++_cookie;

  // from now on, ignore all incoming commits until the block below gets
  // scheduled on raster thread
  _acceptingCommit = NO;

  // let pending commits finish to unblock the raster thread
  _pendingCommit = NO;
  _condBlockBeginResize.notify_all();

  // let the engine send resize notification
  notify();

  _newSize = size;

  _waiting = YES;

  _condBlockRequestCommit.wait(lock, [&] { return _pendingCommit; });

  [_delegate resizeSynchronizerFlush:self];
  [_delegate resizeSynchronizerCommit:self];
  _pendingCommit = NO;
  _condBlockBeginResize.notify_all();

  _waiting = NO;
}

- (BOOL)shouldEnsureSurfaceForSize:(CGSize)size {
  std::unique_lock<std::mutex> lock(_mutex);
  if (!_acceptingCommit) {
    if (CGSizeEqualToSize(_newSize, size)) {
      _acceptingCommit = YES;
    }
  }
  return _acceptingCommit;
}

- (void)requestCommit {
  std::unique_lock<std::mutex> lock(_mutex);
  if (!_acceptingCommit) {
    return;
  }

  _pendingCommit = YES;
  if (_waiting) {  // BeginResize is in progress, interrupt it and schedule commit call
    _condBlockRequestCommit.notify_all();
    _condBlockBeginResize.wait(lock, [&]() { return !_pendingCommit; });
  } else {
    // No resize, schedule commit on platform thread and wait until either done
    // or interrupted by incoming BeginResize
    [_delegate resizeSynchronizerFlush:self];
    dispatch_async(dispatch_get_main_queue(), [self, cookie = _cookie] {
      std::unique_lock<std::mutex> lock(_mutex);
      if (cookie == _cookie) {
        if (_delegate) {
          [_delegate resizeSynchronizerCommit:self];
        }
        _pendingCommit = NO;
        _condBlockBeginResize.notify_all();
      }
    });
    _condBlockBeginResize.wait(lock, [&]() { return !_pendingCommit; });
  }
}

@end

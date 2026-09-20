// Derived from Playwright (https://github.com/microsoft/playwright),
// Copyright (c) Microsoft Corporation, licensed under the Apache License,
// Version 2.0. Ported to Dart and modified; the modifications are summarized
// in the NOTICE file of this package.
//
// Upstream source: packages/isomorphic/lruCache.ts

/// A size-bounded cache that evicts the least recently used entry.
///
/// The snapshot storage keeps one per trace, holding rendered HTML. Rendering
/// a snapshot is a full walk of a DOM tree that may resolve references into
/// several earlier snapshots, so the same snapshot must not be rendered twice
/// as the user scrubs back and forth; keeping every one, on the other hand,
/// would hold the whole page history in memory.
library;

class _Entry<V> {
  final V value;
  final int size;

  _Entry(this.value, this.size);
}

/// A value and the number of bytes it is worth against the budget.
class SizedValue<V> {
  final V value;
  final int size;

  const SizedValue(this.value, this.size);
}

/// An LRU cache bounded by the summed size of its values.
class LruCache<K, V> {
  final int maxSize;

  /// Dart's map preserves insertion order, so the first key is the least
  /// recently used one as long as every hit reinserts.
  final Map<K, _Entry<V>> _map = <K, _Entry<V>>{};
  int _size = 0;

  LruCache(this.maxSize);

  /// The summed size of everything cached right now.
  int get currentSize => _size;

  /// Returns the cached value for [key], computing and storing it first when
  /// it is missing. A value larger than the whole budget is still returned,
  /// after emptying the cache, exactly as upstream does.
  V getOrCompute(K key, SizedValue<V> Function() compute) {
    final cached = _map[key];
    if (cached != null) {
      // Reinserting makes this the most recently used entry.
      _map.remove(key);
      _map[key] = cached;
      return cached.value;
    }

    final result = compute();

    while (_map.isNotEmpty && _size + result.size > maxSize) {
      final firstKey = _map.keys.first;
      _size -= _map[firstKey]!.size;
      _map.remove(firstKey);
    }

    _map[key] = _Entry<V>(result.value, result.size);
    _size += result.size;
    return result.value;
  }
}

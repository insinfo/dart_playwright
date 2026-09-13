import 'locator.dart';

/// A view into an `iframe`, resolved lazily like a [Locator].
///
/// `page.frameLocator('#feed').getByRole('button')` describes "the button
/// inside the frame owned by `#feed`"; nothing is resolved until the locator
/// is used, so the frame may appear later.
abstract class FrameLocator with LocatorFactory {
  /// The locator for the `iframe` element itself.
  Locator get owner;

  /// The frame owned by the first matching `iframe`.
  FrameLocator get first;

  /// The frame owned by the last matching `iframe`.
  FrameLocator get last;

  /// The frame owned by the [index]-th matching `iframe`.
  FrameLocator nth(int index);
}

class FrameLocatorImpl extends FrameLocator {
  final LocatorImpl _owner;

  FrameLocatorImpl(this._owner);

  @override
  Locator get owner => _owner;

  @override
  Locator byParts(List<Map<String, dynamic>> parts) {
    return LocatorImpl(
      _owner.frameImpl,
      _owner.selector.append([Selectors.frame(), ...parts]),
    );
  }

  @override
  FrameLocator get first => FrameLocatorImpl(_owner.first as LocatorImpl);

  @override
  FrameLocator get last => FrameLocatorImpl(_owner.last as LocatorImpl);

  @override
  FrameLocator nth(int index) =>
      FrameLocatorImpl(_owner.nth(index) as LocatorImpl);

  @override
  String toString() => "FrameLocator('${_owner.selector.description}')";
}

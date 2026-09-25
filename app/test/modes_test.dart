import 'package:flutter_test/flutter_test.dart';
import 'package:lenny/services/core_session.dart';
import 'package:lenny/state/modes.dart';

void main() {
  const modes = <StreamMode>[
    (width: 1920, height: 1080, fps: 24),
    (width: 1920, height: 1080, fps: 30),
    (width: 1920, height: 1080, fps: 60),
    (width: 3840, height: 2160, fps: 30),
    (width: 1440, height: 1080, fps: 30),
    (width: 960, height: 720, fps: 30),
    (width: 1080, height: 1080, fps: 30),
  ];
  const now = (width: 1920, height: 1080, fps: 60);

  test('labels', () {
    expect(aspectOf(now), '16:9');
    expect(aspectOf((width: 1440, height: 1080, fps: 30)), '4:3');
    expect(resolutionLabel(2160), '4K');
    expect(resolutionLabel(720), '720p');
  });

  test('fps tap keeps the resolution', () {
    expect(pickMode(modes, now, fps: 24), (width: 1920, height: 1080, fps: 24));
  });

  test('resolution tap keeps the aspect, falls back to the nearest fps', () {
    expect(pickMode(modes, now, height: 2160), (width: 3840, height: 2160, fps: 30)); // no 4K60
  });

  test('aspect tap keeps the height where it can', () {
    expect(pickMode(modes, now, aspect: '4:3'), (width: 1440, height: 1080, fps: 30));
    expect(pickMode(modes, now, aspect: '1:1'), (width: 1080, height: 1080, fps: 30));
  });

  test('no modes, no pick', () => expect(pickMode(const [], now, fps: 30), isNull));
}

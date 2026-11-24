import 'package:flutter_test/flutter_test.dart';
import 'package:nestiq/state/scenes_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('sceny przetrwają zapis i ponowne wczytanie', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ScenesController();
    await first.save(const Scene(id: 'a', name: 'Dobranoc', actions: [
      SceneAction(deviceId: 1, value: 'DOWN'),
      SceneAction(deviceId: 2, value: '50%'),
    ]));
    await first.save(const Scene(id: 'b', name: 'Rano', actions: [
      SceneAction(deviceId: 1, value: 'UP'),
    ]));
    await first.save(const Scene(id: 'a', name: 'Noc', actions: [
      SceneAction(deviceId: 2, value: 'DOWN'),
    ]));
    await first.remove('b');

    final second = ScenesController();
    await second.load();
    expect(second.scenes, hasLength(1));
    expect(second.scenes.single.name, 'Noc');
    expect(second.scenes.single.actions.single.value, 'DOWN');
  });
}

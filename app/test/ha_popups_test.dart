import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/btproxy/esp_entities.dart';
import 'package:kiosk_satellite/managers/home_assistant/ha_popups.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late HaPopups popup;
  late List<(String, Map<String, Object?>)> executed;
  late List<HaEventRequested> fired;
  var pageUp = true;
  late List<Map<String, Object?>> serviceCalls;
  late CommandResult serviceResult;
  void Function()? duringEval;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    pageUp = true;
    duringEval = null;
    executed = [];
    bus = EventBus();
    fired = [];
    bus.on<HaEventRequested>().listen(fired.add);
    final log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    for (final name in [
      'screenOn',
      'bringToFront',
      'stopScreensaver',
      'hideOverlayPage',
    ]) {
      commands.register(
        Command(
          name: name,
          description: 'stub',
          handler: (p) async {
            executed.add((name, p));
            return const CommandResult.ok();
          },
        ),
      );
    }
    serviceCalls = [];
    serviceResult = const CommandResult.ok();
    commands.register(
      Command(
        name: 'haCallService',
        description: 'stub',
        handler: (p) async {
          serviceCalls.add(p);
          return serviceResult;
        },
      ),
    );
    commands.register(
      Command(
        name: 'evalJs',
        description: 'stub',
        handler: (p) async {
          executed.add(('evalJs', p));
          duringEval?.call();
          return pageUp
              ? const CommandResult.ok('null')
              : const CommandResult.fail('no webview');
        },
      ),
    );
    popup = HaPopups(
      bus: bus,
      commands: commands,
      log: log,
      settings: settings,
      evalJs: (p) => commands.execute('evalJs', p),
    )..register();
  });

  Future<Map<String, Object?>> show([
    Map<String, Object?> extra = const {},
  ]) async {
    final r = await commands.execute('showPopup', {
      'title': 'Enter Code',
      'content': jsonEncode([
        {
          'name': 'code',
          'selector': {'keypad': {}},
        },
      ]),
      'right_button': 'Disarm',
      'left_button': 'Cancel',
      ...extra,
    });
    expect(r.ok, isTrue, reason: r.error);
    return (r.data as Map).cast<String, Object?>();
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('shows the popup in the page after waking the panel', () async {
    final out = await show();
    expect(out['id'], 'p1');
    expect(executed.map((c) => c.$1), [
      'screenOn',
      'bringToFront',
      'stopScreensaver',
      'hideOverlayPage',
      'evalJs',
    ]);
    final js = executed.last.$2['code'] as String;
    expect(js, contains('window.__ksPopup.show('));
    expect(js, contains('"title":"Enter Code"'));
    expect(js, contains('"keypad"'));
  });

  test('fails without anything to show or with a bad form', () async {
    expect((await commands.execute('showPopup', {})).ok, isFalse);
    final bad = await commands.execute('showPopup', {
      'title': 'x',
      'content': '{nope',
    });
    expect(bad.ok, isFalse);
    expect(bad.error, contains('content'));
    final notList = await commands.execute('showPopup', {
      'title': 'x',
      'content': '[1]',
    });
    expect(notList.ok, isFalse);
  });

  test('fails when the dashboard is not there', () async {
    pageUp = false;
    final r = await commands.execute('showPopup', {'title': 'x'});
    expect(r.ok, isFalse);
    expect(popup.activeId, isNull);
  });

  test('confirming fires the event with the code', () async {
    final out = await show();
    bus.publish(
      PopupReported(
        id: out['id']! as String,
        outcome: 'confirmed',
        values: const {'code': '1234'},
      ),
    );
    await settle();
    expect(fired, hasLength(1));
    expect(fired.single.name, 'kiosk_satellite_popup');
    expect(fired.single.data, {
      'event_type': 'confirmed',
      'popup_id': 'p1',
      'title': 'Enter Code',
      'message': '',
      'values': '{"code":"1234"}',
      'value': '1234',
    });
    expect(popup.activeId, isNull);
  });

  test('cancelling and timing out carry no values', () async {
    var out = await show();
    bus.publish(
      PopupReported(
        id: out['id']! as String,
        outcome: 'cancelled',
        values: const {'code': '99'},
      ),
    );
    await settle();
    expect(fired.last.data['event_type'], 'cancelled');
    expect(fired.last.data.containsKey('values'), isFalse);
    out = await show();
    bus.publish(
      PopupReported(
        id: out['id']! as String,
        outcome: 'timeout',
        values: const {},
      ),
    );
    await settle();
    expect(fired.last.data['event_type'], 'timeout');
  });

  test('a popup that ends before the page answers is not lost', () async {
    // The form could not be drawn: the page reports from inside the eval.
    duringEval = () => bus.publish(
      const PopupReported(
        id: 'p1',
        outcome: 'error',
        values: {},
        error: 'no such selector',
      ),
    );
    await show({'hold': true});
    await settle();

    expect(popup.activeId, isNull);
    expect(fired.single.data['event_type'], 'error');
    expect(settings.get(defs.haHoldMode), isFalse);
  });

  test('a replacing popup keeps the hold without toggling it', () async {
    await show({'hold': true});
    final changes = <Object?>[];
    bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.haHoldMode.key) changes.add(e.value);
    });

    await show({'hold': true});
    await settle();

    expect(changes, isEmpty);
    expect(settings.get(defs.haHoldMode), isTrue);
    expect(fired.single.data['event_type'], 'replaced');
  });

  test('a failed show leaves no hold or state behind', () async {
    pageUp = false;
    await commands.execute('showPopup', {'title': 'x', 'hold': true});
    await settle();

    expect(popup.activeId, isNull);
    expect(settings.get(defs.haHoldMode), isFalse);
    expect(fired, isEmpty);
  });

  test('a report for a popup it did not open is ignored', () async {
    await show();
    bus.publish(
      const PopupReported(id: 'p99', outcome: 'confirmed', values: {'a': 1}),
    );
    await settle();
    expect(fired, isEmpty);
    expect(popup.activeId, 'p1');
  });

  test('a second popup replaces the first', () async {
    await show();
    final second = await show();
    expect(second['id'], 'p2');
    await settle();
    expect(fired.single.data['event_type'], 'replaced');
    expect(fired.single.data['popup_id'], 'p1');
  });

  test('closePopup takes it down and the page is told', () async {
    await show();
    executed.clear();
    await commands.execute('closePopup', const {});
    await settle();
    expect(fired.single.data['event_type'], 'closed');
    expect((executed.single.$2['code'] as String), contains("close('p1')"));
    // Nothing up is not an error.
    expect((await commands.execute('closePopup', const {})).ok, isTrue);
  });

  test('a page reload ends it', () async {
    await show();
    bus.publish(const DashboardNavigationStarted());
    await settle();
    expect(fired.single.data['event_type'], 'closed');
  });

  test('hold mode is on for the stay and off after', () async {
    final out = await show({'hold': true});
    await settle();
    expect(settings.get(defs.haHoldMode), isTrue);
    bus.publish(
      PopupReported(
        id: out['id']! as String,
        outcome: 'dismissed',
        values: const {},
      ),
    );
    await settle();
    expect(settings.get(defs.haHoldMode), isFalse);
  });

  test('a hold that was already on stays', () async {
    await settings.set(defs.haHoldMode, true);
    final out = await show({'hold': true});
    bus.publish(
      PopupReported(
        id: out['id']! as String,
        outcome: 'dismissed',
        values: const {},
      ),
    );
    await settle();
    expect(settings.get(defs.haHoldMode), isTrue);
  });

  test('the app ends a popup whose page never answers', () async {
    // 0.01s timeout is under the grace; use a fake clock-free check by
    // reading the cap instead of waiting.
    final out = await show({'timeout': 5});
    final js = executed.last.$2['code'] as String;
    expect(js, contains('"timeout":5000'));
    expect(out['id'], 'p1');
  });

  group('button actions', () {
    const disarm =
        '{"action": "alarm_control_panel.alarm_disarm", '
        '"target": {"entity_id": "alarm_control_panel.home"}, '
        '"data": {"code": "{value}", "note": "code {value}"}}';

    test('the right button runs its action with what was entered', () async {
      final out = await show({'right_button_action': disarm});
      bus.publish(
        PopupReported(
          id: out['id']! as String,
          outcome: 'confirmed',
          values: const {'code': '1234'},
        ),
      );
      await settle();
      await settle();
      expect(serviceCalls, [
        {
          'domain': 'alarm_control_panel',
          'service': 'alarm_disarm',
          'target': {'entity_id': 'alarm_control_panel.home'},
          'data': {'code': '1234', 'note': 'code 1234'},
        },
      ]);
      expect(fired.single.data['event_type'], 'confirmed');
      expect(fired.single.data.containsKey('action_error'), isFalse);
    });

    test('the left button runs its own, and only a button runs one', () async {
      final left = await show({
        'left_button_action': '{"action": "script.cancelled"}',
        'right_button_action': disarm,
      });
      bus.publish(
        PopupReported(
          id: left['id']! as String,
          outcome: 'cancelled',
          values: const {},
        ),
      );
      await settle();
      await settle();
      expect(serviceCalls.single['service'], 'cancelled');

      serviceCalls.clear();
      final timed = await show({'right_button_action': disarm});
      bus.publish(
        PopupReported(
          id: timed['id']! as String,
          outcome: 'timeout',
          values: const {},
        ),
      );
      await settle();
      expect(serviceCalls, isEmpty);
    });

    test('a failed call still fires the event, saying why', () async {
      serviceResult = const CommandResult.fail('no such service');
      final out = await show({'right_button_action': disarm});
      bus.publish(
        PopupReported(
          id: out['id']! as String,
          outcome: 'confirmed',
          values: const {'code': '1'},
        ),
      );
      await settle();
      await settle();
      expect(fired.single.data['action_error'], 'no such service');
    });

    test('a placeholder alone keeps the value as it is', () async {
      final out = await show({
        'content': jsonEncode([
          {
            'name': 'level',
            'selector': {'number': {}},
          },
        ]),
        'right_button_action':
            '{"action": "light.turn_on", "data": {"brightness": "{level}"}}',
      });
      bus.publish(
        PopupReported(
          id: out['id']! as String,
          outcome: 'confirmed',
          values: const {'level': 50},
        ),
      );
      await settle();
      await settle();
      expect((serviceCalls.single['data']! as Map)['brightness'], 50);
    });

    test('refuses a bad action or one with no button', () async {
      for (final extra in <Map<String, Object?>>[
        {'right_button_action': '{nope'},
        {'right_button_action': '{"action": "nodot"}'},
        {'right_button_action': '[1]'},
        {'right_button': '', 'right_button_action': disarm},
      ]) {
        final r = await commands.execute('showPopup', {'title': 'x', ...extra});
        expect(r.ok, isFalse, reason: '$extra');
      }
      expect(popup.activeId, isNull);
    });
  });

  group('ESPHome popup action', () {
    test('popup_custom and popup_message are listed', () {
      final surface = EspEntitySurface(bus, commands, Logger(), settings);
      final services = surface.buildServices();
      List<Object?> argNames(String n) => [
        for (final a
            in services.singleWhere((s) => s['name'] == n)['args']! as List)
          (a as Map)['name'],
      ];
      expect(
        argNames('popup_custom'),
        containsAll(['left_button_action', 'right_button_action']),
      );
      expect(argNames('popup'), isNot(contains('left_button_action')));
      expect(argNames('popup_message'), [
        'title',
        'message',
        'button',
        'timeout',
      ]);
    });

    test('popup_message is a message with one button', () async {
      final surface = EspEntitySurface(bus, commands, Logger(), settings);
      final out = await surface.handleService('popup_message', {
        'title': 'Hi',
        'message': 'Dinner',
        'button': 'OK',
        'timeout': 0,
      });
      expect(out, {'id': 'p1'});
      final js = executed.last.$2['code'] as String;
      expect(js, contains('"right_button":"OK"'));
      expect(js, contains('"left_button":null'));
    });

    test('popup_custom carries the actions; popup drops them', () async {
      final surface = EspEntitySurface(bus, commands, Logger(), settings);
      Future<Map<String, Object?>?> run(String name) =>
          surface.handleService(name, {
            'title': 'x',
            'content': '',
            'left_button': '',
            'left_button_action': '',
            'right_button': 'Go',
            'right_button_action': '{"action": "script.go"}',
            'timeout': 0,
            'dismissable': true,
            'hold_mode': false,
          });
      await run('popup_custom');
      bus.publish(
        const PopupReported(id: 'p1', outcome: 'confirmed', values: {}),
      );
      await settle();
      await settle();
      expect(serviceCalls.single['service'], 'go');

      serviceCalls.clear();
      await run('popup');
      bus.publish(
        const PopupReported(id: 'p2', outcome: 'confirmed', values: {}),
      );
      await settle();
      await settle();
      expect(serviceCalls, isEmpty);
    });

    test('is listed and answers', () {
      final surface = EspEntitySurface(bus, commands, Logger(), settings);
      final services = surface.buildServices();
      final popupService = services.singleWhere((s) => s['name'] == 'popup');
      expect(popupService['supportsResponse'], isTrue);
      expect(
        (popupService['args']! as List).map((a) => (a as Map)['name']),
        containsAll(['title', 'content', 'timeout', 'hold_mode']),
      );
      expect(services.any((s) => s['name'] == 'popup_close'), isTrue);
    });

    test('passes the arguments through and answers with the id', () async {
      final surface = EspEntitySurface(bus, commands, Logger(), settings);
      final out = await surface.handleService('popup', {
        'title': 'Enter Code',
        'content': '[{"name":"code","selector":{"keypad":{}}}]',
        'left_button': 'Cancel',
        'right_button': 'Disarm',
        'timeout': 30,
        'dismissable': true,
        'hold_mode': true,
      });
      expect(out, {'id': 'p1'});
      expect(settings.get(defs.haHoldMode), isTrue);
    });
  });
}

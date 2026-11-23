import 'dart:async';
import 'dart:convert';

import '../../core/command_registry.dart';
import '../../core/event_bus.dart';
import '../../core/events.dart';
import '../../core/logging.dart';
import '../browser/popup_script.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// A dialog Home Assistant asks the dashboard to show: a title, some text,
/// optionally a form (drawn by Home Assistant's own `ha-form`, so custom
/// selectors like a keypad work) and up to two buttons. The kiosk's answer
/// to Browser Mod's `browser_mod.popup`.
///
/// How it ends goes back to Home Assistant as
/// `esphome.kiosk_satellite_popup`, with the form's values when the right
/// button was pressed: the automation that asked decides what a code means,
/// the kiosk never sees a service call.
///
/// The dialog itself is script in the page (browser/popup_script.dart); this
/// class owns what the app needs to know: which popup is up, the hold it
/// took, a timer that outlives the page's own, and the event. It is part of
/// [HomeAssistantManager], which registers it and passes its page-guarded
/// evalJs, so a popup without a dashboard page fails the way the manager's
/// other page features do.
class HaPopups {
  HaPopups({
    required this.bus,
    required this.commands,
    required this.log,
    required SettingsManager settings,
    required Future<CommandResult> Function(Map<String, Object?>) evalJs,
  }) : _settings = settings,
       _evalJs = evalJs;

  final EventBus bus;
  final CommandRegistry commands;
  final Logger log;
  final SettingsManager _settings;
  final Future<CommandResult> Function(Map<String, Object?>) _evalJs;

  static const name = 'home_assistant';
  StreamSubscription<PopupReported>? _reportSub;
  StreamSubscription<DashboardNavigationStarted>? _navSub;
  StreamSubscription<SettingChanged>? _settingSub;

  /// Longest a popup may stay up. Nothing on a wall should wait for an
  /// answer for longer than a day.
  static const maxTimeout = Duration(hours: 24);

  /// The page counts the timeout itself; the app's timer fires this much
  /// later, so a page that stopped answering still lets go of its hold.
  static const _grace = Duration(seconds: 3);

  int _nextId = 0;
  String? _activeId;
  Map<String, Object?> _active = const {};

  /// What the buttons of the popup up now run, if anything.
  Map<String, Object?>? _leftAction;
  Map<String, Object?>? _rightAction;
  Timer? _timer;

  /// Whether this popup turned hold mode on for its stay.
  bool _ownsHold = false;

  /// The id of the popup up now, or null.
  String? get activeId => _activeId;

  void register() {
    commands
      ..register(
        Command(
          name: 'showPopup',
          description:
              'Show a dialog over the dashboard, with an optional form drawn '
              'by Home Assistant (so custom selectors such as a keypad '
              'work). How it ends is fired as '
              'esphome.kiosk_satellite_popup. Answers with the popup id.',
          params: const {
            'title': 'heading of the dialog; optional',
            'message': 'plain text under the heading; optional',
            'content':
                'the form, as Home Assistant form schema: a list of '
                '{name, selector, label?, default?}; a JSON string is read '
                'as that list. The values come back with the confirm event',
            'left_button': 'text of the left (cancel) button; omitted for none',
            'right_button':
                'text of the right (confirm) button; omitted for none',
            'left_button_action':
                'a Home Assistant action the left button runs: {action: '
                '"domain.service", target?, data?}, as a map or JSON string. '
                'In data, {value} is the form\'s only field and {name} a '
                'field by its name',
            'right_button_action':
                'the same for the right button, which runs it with what the '
                'form holds',
            'timeout':
                'seconds until the popup closes itself; 0 or omitted stays '
                'until answered',
            'dismissable':
                'whether the close button, a tap outside and Escape close it '
                '(default true)',
            'hold':
                'true turns hold mode on while the popup is up and off '
                'again after; a hold already on is left alone',
          },
          handler: (p) async => _show(p),
        ),
      )
      ..register(
        Command(
          name: 'closePopup',
          description:
              'Close the popup on the dashboard, if there is one; Home '
              'Assistant hears it as closed',
          handler: (_) async {
            final id = _activeId;
            if (id != null) await _end(id, 'closed', const {}, tellPage: true);
            return const CommandResult.ok();
          },
        ),
      );

    _reportSub = bus.on<PopupReported>().listen((e) {
      // Any page can send this; only the popup the app opened counts.
      if (e.id != _activeId) return;
      unawaited(
        _end(
          e.id,
          const {
                'confirmed',
                'cancelled',
                'dismissed',
                'timeout',
                'error',
              }.contains(e.outcome)
              ? e.outcome
              : 'dismissed',
          e.values,
          error: e.error,
        ),
      );
    });

    // The document that held the popup is gone.
    _navSub = bus.on<DashboardNavigationStarted>().listen((_) {
      final id = _activeId;
      if (id != null) unawaited(_end(id, 'closed', const {}));
    });

    // A hold released by anyone else is no longer the popup's to release.
    _settingSub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.haHoldMode.key && e.value == false) _ownsHold = false;
    });
  }

  Future<CommandResult> _show(Map<String, Object?> p) async {
    final title = '${p['title'] ?? ''}'.trim();
    final message = '${p['message'] ?? ''}'.trim();
    final List<Object?> content;
    try {
      content = _form(p['content']);
    } on FormatException catch (e) {
      return CommandResult.fail('content: ${e.message}');
    }

    final left = _text(p['left_button']);
    final right = _text(p['right_button']);

    final Map<String, Object?>? leftAction;
    final Map<String, Object?>? rightAction;
    try {
      leftAction = _buttonAction(p['left_button_action']);
      rightAction = _buttonAction(p['right_button_action']);
    } on FormatException catch (e) {
      return CommandResult.fail(e.message);
    }

    if (leftAction != null && left == null) {
      return const CommandResult.fail('left_button_action needs left_button');
    }
    if (rightAction != null && right == null) {
      return const CommandResult.fail('right_button_action needs right_button');
    }

    if (title.isEmpty && message.isEmpty && content.isEmpty) {
      return const CommandResult.fail('title, message or content required');
    }

    final seconds = p['timeout'] is num
        ? (p['timeout'] as num).toDouble()
        : double.tryParse('${p['timeout'] ?? ''}') ?? 0;
    final timeout = seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : Duration.zero;
    final capped = timeout > maxTimeout ? maxTimeout : timeout;

    final dismissable = p['dismissable'] == null || p['dismissable'] == true;

    // The popup is meant to be seen: a dark or sleeping panel, the
    // screensaver and a page over the dashboard would all hide it.
    await commands.execute('screenOn', const {});
    await commands.execute('bringToFront', const {});
    await commands.execute('stopScreensaver', const {});
    await commands.execute('hideOverlayPage', const {});


    final hold = p['hold'] == true;
    // A replaced popup's hold carries over instead of being let go and taken
    // again, which would flip the setting for everything listening to it.
    final carriedHold = _ownsHold;
    final previous = _activeId;
    if (previous != null) {
      await _end(
        previous,
        'replaced',
        const {},
        tellPage: false,
        releaseHold: false,
      );
    }

    final id = 'p${++_nextId}';

    final config = {
      'id': id,
      'title': title,
      'message': message,
      'content': content,
      'left_button': left,
      'right_button': right,
      'timeout': capped.inMilliseconds,
      'dismissable': dismissable,
    };

    // Registered before the page is told: a dialog that ends at once (a
    // form it cannot draw, a very short timeout) reports before the eval
    // below returns, and a report for an id the app does not know yet
    // would be dropped.
    _activeId = id;
    _active = {'title': title, 'message': message};
    _leftAction = leftAction;
    _rightAction = rightAction;
    _ownsHold = carriedHold;

    if (hold && !_settings.get(defs.haHoldMode)) {
      _ownsHold = true;
      unawaited(_settings.set(defs.haHoldMode, true));
    } else if (!hold && _ownsHold) {
      _ownsHold = false;
      unawaited(_settings.set(defs.haHoldMode, false));
    }

    _timer?.cancel();
    if (capped > Duration.zero) {
      _timer = Timer(capped + _grace, () {
        if (_activeId == id) {
          unawaited(_end(id, 'timeout', const {}, tellPage: true));
        }
      });
    }

    final result = await _evalJs({'code': popupShowJs(jsonEncode(config))});
    if (!result.ok) {
      // Nothing was shown, so there is nothing to tell Home Assistant.
      if (_activeId == id) {
        _clear();
        _releaseHold();
      }
      return CommandResult.fail(result.error ?? 'the dashboard is not open');
    }

    log.info(
      name,
      'popup $id${capped > Duration.zero ? ' (${capped.inSeconds}s)' : ''}'
      '${hold ? ' holding' : ''}',
    );
    return CommandResult.ok({'id': id});
  }

  /// Ends popup [id], however it ended. Lets go of its hold and tells Home
  /// Assistant. [tellPage] takes the dialog down when the page did not
  /// already.
  Future<void> _end(
    String id,
    String outcome,
    Map<String, Object?> values, {
    bool tellPage = false,
    bool releaseHold = true,
    String error = '',
  }) async {
    if (id != _activeId) return;

    final info = _active;
    // Only the buttons run an action: a timeout or a tap outside does not.
    final action = switch (outcome) {
      'confirmed' => _rightAction,
      'cancelled' => _leftAction,
      _ => null,
    };

    _clear();
    if (tellPage) {
      unawaited(_evalJs({'code': popupCloseJs(id)}));
    }

    if (releaseHold) _releaseHold();

    String actionError = '';
    if (action != null) {
      actionError = await _runAction(
        action,
        outcome == 'confirmed' ? values : const {},
      );
    }

    final event = switch (outcome) {
      'confirmed' => 'confirmed',
      'cancelled' => 'cancelled',
      'timeout' => 'timeout',
      'error' => 'error',
      'dismissed' => 'dismissed',
      'replaced' => 'replaced',
      _ => 'closed',
    };

    final data = <String, Object?>{
      'event_type': event,
      'popup_id': id,
      'title': info['title'] ?? '',
      'message': info['message'] ?? '',
    };

    if (event == 'confirmed') {
      data['values'] = jsonEncode(values);
      // A one field form (a code, a name) is the common case; its value
      // is a field of its own, so the automation need not decode JSON.
      if (values.length == 1) data['value'] = '${values.values.first ?? ''}';
    }

    if (error.isNotEmpty) data['error'] = error;
    // The button's action failed; the event still tells Home Assistant the
    // button was pressed.
    if (actionError.isNotEmpty) data['action_error'] = actionError;

    bus.publish(HaEventRequested('kiosk_satellite_popup', data));
    log.info(name, 'popup $id $event');
  }

  void _clear() {
    _activeId = null;
    _active = const {};
    _leftAction = null;
    _rightAction = null;
    _timer?.cancel();
  }

  /// Lets go of the hold this popup took, unless someone released it first.
  void _releaseHold() {
    if (!_ownsHold) return;
    _ownsHold = false;
    if (_settings.get(defs.haHoldMode)) {
      unawaited(_settings.set(defs.haHoldMode, false));
    }
  }

  /// Runs a button's action as a Home Assistant service call. Answers the
  /// reason it failed, or an empty string.
  Future<String> _runAction(
    Map<String, Object?> action,
    Map<String, Object?> values,
  ) async {
    final service = '${action['action']}'.split('.');

    final filled = <String, Object?>{
      if (values.length == 1) 'value': values.values.first,
      ...values,
    };

    final data = action['data'];
    final target = action['target'];

    try {
      final result = await commands
          .execute('haCallService', {
            'domain': service.first,
            'service': service.sublist(1).join('.'),
            if (target is Map) 'target': _fill(target, filled),
            if (data is Map) 'data': _fill(data, filled),
          })
          .timeout(const Duration(seconds: 15));
      if (!result.ok) {
        log.warn(name, 'popup action ${action['action']}: ${result.error}');
        return result.error ?? 'failed';
      }
      return '';
    } on TimeoutException {
      return '${action['action']} timed out';
    } catch (e) {
      log.warn(name, 'popup action ${action['action']}: $e');
      return '$e';
    }
  }

  /// [template] with `{key}` filled from [values]. A string that is only a
  /// placeholder keeps the value's own type, a list from a multi select
  /// for one.
  static Object? _fill(Object? template, Map<String, Object?> values) {
    if (template is String) {
      final whole = RegExp(r'^\{(\w+)\}$').firstMatch(template);
      if (whole != null && values.containsKey(whole.group(1))) {
        return values[whole.group(1)];
      }
      return template.replaceAllMapped(
        // Not the inside of a `{{ template }}`, which is Home Assistant's.
        RegExp(r'(?<!\{)\{(\w+)\}(?!\})'),
        (m) => values.containsKey(m.group(1))
            ? '${values[m.group(1)] ?? ''}'
            : m.group(0)!,
      );
    }
    if (template is Map) {
      return {
        for (final e in template.entries) '${e.key}': _fill(e.value, values),
      };
    }
    if (template is List) {
      return [for (final e in template) _fill(e, values)];
    }
    return template;
  }

  /// A button's action from a map, or a JSON string holding one (what an
  /// ESPHome action sends). Empty is no action.
  static Map<String, Object?>? _buttonAction(Object? raw) {
    if (raw == null) return null;
    var value = raw;
    if (value is String) {
      if (value.trim().isEmpty) return null;
      try {
        value = jsonDecode(value);
      } on FormatException {
        throw const FormatException('a button action is not valid JSON');
      }
    }
    if (value is! Map) {
      throw const FormatException('a button action must be a mapping');
    }
    final action = value['action'];
    if (action is! String || !RegExp(r'^\w+\.\w+$').hasMatch(action)) {
      throw const FormatException(
        'a button action needs action: domain.service',
      );
    }
    for (final key in const ['data', 'target']) {
      if (value[key] != null && value[key] is! Map) {
        throw FormatException('a button action\'s $key must be a mapping');
      }
    }
    return value.cast<String, Object?>();
  }

  static String? _text(Object? v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty ? null : s;
  }

  /// The form schema from a list, or from a JSON string holding one (what
  /// an ESPHome action, which carries only strings, sends).
  static List<Object?> _form(Object? raw) {
    if (raw == null) return const [];
    var value = raw;
    if (value is String) {
      if (value.trim().isEmpty) return const [];
      try {
        value = jsonDecode(value);
      } on FormatException {
        throw const FormatException('not valid JSON');
      }
    }
    if (value is Map) value = [value];
    if (value is! List) {
      throw const FormatException('expected a list of fields');
    }
    for (final field in value) {
      if (field is! Map) {
        throw const FormatException('every field must be a mapping');
      }
    }
    return List<Object?>.from(value);
  }

  void dispose() {
    _timer?.cancel();
    _reportSub?.cancel();
    _navSub?.cancel();
    _settingSub?.cancel();
  }
}

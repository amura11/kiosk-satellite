/// The popup the dashboard shows for the `popup` action: a dialog in the
/// Home Assistant page itself, so a form field is drawn by Home Assistant's
/// own `ha-form` and any selector a custom integration registers (a keypad,
/// say) works the way it does in a Browser Mod popup.
///
/// The dialog is this script's own element (a backdrop, a card, a title,
/// the form and two buttons), not `ha-dialog`: that element changes between
/// Home Assistant releases, and a popup that must show up when the alarm
/// goes off is a poor place to depend on its internals. It borrows the
/// theme through CSS variables, which Home Assistant sets on the document.
///
/// [popupShowJs] defines `window.__ksPopup` once and opens a popup from a
/// config; the page reports how it ended through the `ksApi` handler's
/// `popupResult` call. A popup the app closes (`close`) reports nothing.
const popupScript = r'''
(function () {
  if (window.__ksPopup) return;
  var current = null;

  function report(id, outcome, values, error) {
    try {
      window.flutter_inappwebview.callHandler('ksApi', 'popupResult', {
        id: id, outcome: outcome, values: values || {}, error: error || ''
      });
    } catch (e) {}
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function haRoot() {
    return document.querySelector('home-assistant') ||
      document.querySelector('hc-main');
  }

  // ha-form is loaded lazily with the card editors. Creating a card and
  // asking for its editor is how Browser Mod makes the frontend load it.
  async function loadHaForm() {
    if (customElements.get('ha-form')) return;
    var deadline = Date.now() + 10000;
    while (!window.loadCardHelpers && Date.now() < deadline) {
      try {
        await customElements.whenDefined('partial-panel-resolver');
        var resolver = document.createElement('partial-panel-resolver');
        var routes = resolver._getRoutes([
          { component_name: 'lovelace', url_path: 'a' }
        ]);
        if (routes && routes.routes && routes.routes.a && routes.routes.a.load) {
          await routes.routes.a.load();
        }
      } catch (e) {}
      if (!window.loadCardHelpers) await sleep(250);
    }
    if (window.loadCardHelpers && !customElements.get('ha-form')) {
      try {
        var helpers = await window.loadCardHelpers();
        var card = await helpers.createCardElement({ type: 'button' });
        if (card && card.constructor.getConfigElement) {
          await card.constructor.getConfigElement();
        }
      } catch (e) {}
    }
    await Promise.race([
      customElements.whenDefined('ha-form'),
      sleep(Math.max(1000, deadline - Date.now()))
    ]);
    if (!customElements.get('ha-form')) throw new Error('ha-form unavailable');
  }

  var CSS = [
    ':host { all: initial; }',
    '.backdrop { position: fixed; inset: 0; z-index: 2147483000;',
    '  display: flex; align-items: center; justify-content: center;',
    '  background: rgba(0, 0, 0, 0.55); font-family: var(--ha-font-family-body,',
    '  var(--paper-font-body1_-_font-family, Roboto, sans-serif)); }',
    '.card { position: relative; box-sizing: border-box; overflow: hidden;',
    '  display: flex; flex-direction: column;',
    '  width: min(92vw, 420px); max-height: 94vh;',
    '  background: var(--ha-dialog-surface-background,',
    '    var(--mdc-theme-surface, var(--card-background-color, #fff)));',
    '  color: var(--primary-text-color, #212121);',
    '  border-radius: var(--ha-dialog-border-radius, 28px);',
    '  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.45); }',
    '.bar { position: absolute; top: 0; left: 0; height: 3px; width: 100%;',
    '  background: var(--primary-color, #03a9f4); transform-origin: left;',
    '  transition-property: transform; transition-timing-function: linear; }',
    '.head { display: flex; align-items: center; gap: 8px;',
    '  padding: 16px 12px 4px 24px; }',
    '.title { flex: 1; margin: 0; font-size: 22px; font-weight: 400;',
    '  line-height: 28px; }',
    '.close { background: none; border: none; cursor: pointer; padding: 8px;',
    '  color: var(--secondary-text-color, #727272); font-size: 22px;',
    '  line-height: 1; border-radius: 50%; }',
    '.body { overflow: auto; padding: 8px 24px 8px 24px; }',
    '.message { margin: 4px 0 8px; font-size: 16px; line-height: 22px;',
    '  white-space: pre-wrap; }',
    '.foot { display: flex; justify-content: space-between; gap: 12px;',
    '  padding: 8px 16px 16px 16px; }',
    '.foot button { font: inherit; font-size: 15px; font-weight: 500;',
    '  min-height: 44px; min-width: 96px; padding: 0 20px; cursor: pointer;',
    '  border: none; border-radius: 22px; background: transparent;',
    '  color: var(--primary-color, #03a9f4); }',
    '.foot button.confirm { background: var(--primary-color, #03a9f4);',
    '  color: var(--text-primary-color, #fff); }',
    '.foot .gap { flex: 1; }',
    '.error { color: var(--error-color, #db4437); padding: 8px 0; }'
  ].join('\n');

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function teardown(p) {
    if (!p || p.closed) return;
    p.closed = true;
    clearTimeout(p.timer);
    document.removeEventListener('keydown', p.onKey, true);
    if (p.host.parentNode) p.host.parentNode.removeChild(p.host);
    if (current === p) current = null;
  }

  function finish(p, outcome) {
    if (p.closed) return;
    var values = outcome === 'confirmed' ? (p.data || {}) : {};
    teardown(p);
    report(p.id, outcome, values);
  }

  function show(cfg) {
    if (current) teardown(current);
    var p = { id: String(cfg.id), data: {}, closed: false };
    current = p;

    var host = document.createElement('div');
    host.setAttribute('data-ks-popup', p.id);
    var root = host.attachShadow({ mode: 'open' });
    var style = document.createElement('style');
    style.textContent = CSS;
    root.appendChild(style);

    var backdrop = el('div', 'backdrop');
    var card = el('div', 'card');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    backdrop.appendChild(card);

    if (cfg.timeout > 0) {
      var bar = el('div', 'bar');
      bar.style.transitionDuration = cfg.timeout + 'ms';
      card.appendChild(bar);
      // Two frames: the transition needs the full-width bar painted first.
      requestAnimationFrame(function () {
        requestAnimationFrame(function () { bar.style.transform = 'scaleX(0)'; });
      });
      p.timer = setTimeout(function () { finish(p, 'timeout'); }, cfg.timeout);
    }

    if (cfg.title || cfg.dismissable) {
      var head = el('div', 'head');
      head.appendChild(el('h2', 'title', cfg.title || ''));
      if (cfg.dismissable) {
        var x = el('button', 'close', '✕');
        x.setAttribute('aria-label', 'Close');
        x.addEventListener('click', function () { finish(p, 'dismissed'); });
        head.appendChild(x);
      }
      card.appendChild(head);
    }

    var body = el('div', 'body');
    if (cfg.message) body.appendChild(el('div', 'message', cfg.message));
    card.appendChild(body);

    var confirmBtn = null;
    if (cfg.left_button != null || cfg.right_button != null) {
      var foot = el('div', 'foot');
      if (cfg.left_button != null) {
        var left = el('button', 'cancel', cfg.left_button);
        left.addEventListener('click', function () { finish(p, 'cancelled'); });
        foot.appendChild(left);
      } else {
        foot.appendChild(el('span', 'gap'));
      }
      if (cfg.right_button != null) {
        confirmBtn = el('button', 'confirm', cfg.right_button);
        confirmBtn.addEventListener('click', function () { finish(p, 'confirmed'); });
        foot.appendChild(confirmBtn);
      }
      card.appendChild(foot);
    }

    if (cfg.dismissable) {
      backdrop.addEventListener('click', function (ev) {
        if (ev.target === backdrop) finish(p, 'dismissed');
      });
      p.onKey = function (ev) {
        if (ev.key === 'Escape') finish(p, 'dismissed');
      };
      document.addEventListener('keydown', p.onKey, true);
    }

    root.appendChild(backdrop);
    p.host = host;
    (document.body || document.documentElement).appendChild(host);

    if (Array.isArray(cfg.content) && cfg.content.length) {
      if (confirmBtn) confirmBtn.disabled = true;
      var fail = function (e) {
        if (p.closed) return;
        var msg = String((e && e.message) || e);
        body.appendChild(el('div', 'error', msg));
        report(p.id, 'error', {}, msg);
        // The app has ended it by now; leave the reason up a moment, so a
        // dialog that vanishes is not a mystery.
        setTimeout(function () { teardown(p); }, 5000);
      };

      loadHaForm().then(function () {
        if (p.closed) return;

        var form = document.createElement('ha-form');
        var hassEl = haRoot();
        form.hass = hassEl && hassEl.hass;
        form.schema = cfg.content;
        form.computeLabel = function (s) { return s.label != null ? s.label : s.name; };

        (function seed(schema) {
          schema.forEach(function (s) {
            if (s.schema) seed(s.schema);
            else if (s.name && s.default !== undefined) p.data[s.name] = s.default;
          });
        })(cfg.content);

        form.data = p.data;
        form.addEventListener('value-changed', function (ev) {
          ev.stopPropagation();
          p.data = Object.assign({}, ev.detail.value);
          form.data = p.data;
        });

        // A selector's own dialogs must not close this one.
        form.addEventListener('closing', function (ev) {
          ev.stopPropagation();
          ev.preventDefault();
        });

        body.appendChild(form);
        if (confirmBtn) confirmBtn.disabled = false;
      }).catch(fail);
    }
  }

  window.__ksPopup = {
    show: show,
    close: function (id) {
      if (current && (id == null || current.id === String(id))) teardown(current);
    },
    get openId() { return current ? current.id : null; }
  };
})();
''';

/// The script that opens a popup from [configJson] (already JSON).
String popupShowJs(String configJson) =>
    '$popupScript\nwindow.__ksPopup.show($configJson);';

/// The script that takes popup [id] down without reporting.
String popupCloseJs(String id) =>
    'if (window.__ksPopup) window.__ksPopup.close(${_quote(id)});';

String _quote(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

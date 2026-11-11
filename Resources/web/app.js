// Terminaly web client. Speaks the daemon's own frame protocol over a WebSocket:
// one binary message = one frame [UInt32 BE length][UInt8 kind][payload]. `tly web` authenticates
// the socket and filters requests; everything else is the same as the Mac app.
(() => {
  "use strict";

  const KIND_JSON = 1, KIND_OUTPUT = 2, KIND_INPUT = 3;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const $ = (id) => document.getElementById(id);

  // MARK: Strings

  const strings = {
    en: {
      loginHelp: "Paste the access token from Terminaly → Settings → Web on your Mac.",
      tokenPlaceholder: "Access token", connect: "Connect", logout: "Sign out", sessions: "Sessions",
      empty: "Pick a session.", noSessions: "No sessions running on the Mac.",
      permission: "Needs your permission", allow: "Allow", deny: "Deny", pause: "Pause", resume: "Resume",
      badToken: "That token is not valid.", unreachable: "Can't reach the session host on the Mac.",
      reconnecting: "Reconnecting…",
      starting: "Starting", working: "Working", idle: "Ready", needsInput: "Needs input", paused: "Paused", exited: "Exited",
      shell: "Shell",
    },
    es: {
      loginHelp: "Pega el token de acceso de Terminaly → Ajustes → Web de tu Mac.",
      tokenPlaceholder: "Token de acceso", connect: "Conectar", logout: "Cerrar sesión", sessions: "Sesiones",
      empty: "Elige una sesión.", noSessions: "No hay sesiones abiertas en el Mac.",
      permission: "Necesita tu permiso", allow: "Permitir", deny: "Denegar", pause: "Pausar", resume: "Reanudar",
      badToken: "El token no es válido.", unreachable: "No se puede contactar con el host de sesiones del Mac.",
      reconnecting: "Reconectando…",
      starting: "Arrancando", working: "Trabajando", idle: "Listo", needsInput: "Pide respuesta", paused: "En pausa", exited: "Terminado",
      shell: "Shell",
    },
  };
  const lang = (navigator.languages || [navigator.language]).some((l) => /^(es|ca|gl|eu)\b/i.test(l)) ? "es" : "en";
  const t = (key) => strings[lang][key] ?? strings.en[key] ?? key;
  document.documentElement.lang = lang;
  for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of document.querySelectorAll("[data-i18n-placeholder]")) el.placeholder = t(el.dataset.i18nPlaceholder);
  for (const el of document.querySelectorAll("[data-i18n-label]")) el.setAttribute("aria-label", t(el.dataset.i18nLabel));

  // MARK: Storage (a private window may refuse it; the page still works for this visit)

  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} },
  };

  // MARK: Frames

  function frame(kind, payload) {
    const out = new Uint8Array(5 + payload.length);
    new DataView(out.buffer).setUint32(0, payload.length + 1);
    out[4] = kind;
    out.set(payload, 5);
    return out;
  }
  const jsonFrame = (msg) => frame(KIND_JSON, encoder.encode(JSON.stringify(msg)));
  function uuidBytes(id) {
    const hex = id.replace(/-/g, "");
    const b = new Uint8Array(16);
    for (let i = 0; i < 16; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
    return b;
  }
  function bytesUUID(b) {
    const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("").toUpperCase();
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }
  function inputFrame(id, bytes) {
    const p = new Uint8Array(16 + bytes.length);
    p.set(uuidBytes(id));
    p.set(bytes, 16);
    return frame(KIND_INPUT, p);
  }

  // MARK: State

  const sessions = new Map(); // id → SessionInfo from the daemon
  let titles = {};            // id → {title, project} from the app's state file
  let current = store.get("session");
  let attached = null;
  let ws = null;
  let token = null;
  let nextReq = 1;
  const pending = new Map();
  let retryDelay = 1000;
  let retryTimer = null;

  // Tokens can arrive in the link (#token=…) so the Mac can show one URL to open; never keep it in the address bar.
  const hashToken = new URLSearchParams(location.hash.slice(1)).get("token");
  if (hashToken) {
    store.set("token", hashToken);
    history.replaceState(null, "", location.pathname);
  }
  token = store.get("token");

  // MARK: Terminal

  const term = new Terminal({
    fontFamily: 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace',
    fontSize: matchMedia("(max-width: 720px)").matches ? 12 : 13,
    cursorBlink: true,
    scrollback: 10000,
    allowProposedApi: false,
    theme: {
      background: "#0F1013", foreground: "#D4D4DC", cursor: "#ECECF1", cursorAccent: "#0F1013",
      selectionBackground: "rgba(76, 141, 255, 0.35)",
      black: "#1A1B20", red: "#FF6B6B", green: "#3DD68C", yellow: "#FFB020",
      blue: "#4C8DFF", magenta: "#C792EA", cyan: "#5CCFE6", white: "#D4D4DC",
      brightBlack: "#5C5E66", brightRed: "#FF8787", brightGreen: "#6BE3A8", brightYellow: "#FFC85C",
      brightBlue: "#7AABFF", brightMagenta: "#DDB3FF", brightCyan: "#8BE0F0", brightWhite: "#ECECF1",
    },
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  let termOpened = false;

  term.onData((d) => sendInput(encoder.encode(d)));
  term.onBinary((d) => sendInput(Uint8Array.from(d, (c) => c.charCodeAt(0) & 0xff)));
  term.onResize(({ cols, rows }) => {
    if (attached) send({ type: "resize", id: attached, cols, rows });
  });

  let fitTimer = null;
  function refit() {
    clearTimeout(fitTimer);
    fitTimer = setTimeout(() => { if (termOpened && !$("terminal-card").hidden) fit.fit(); }, 60);
  }
  new ResizeObserver(refit).observe($("terminal-card"));

  // MARK: Connection

  function send(msg, reply) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const m = { ...msg, reqID: nextReq++ };
    if (reply) pending.set(m.reqID, reply);
    ws.send(jsonFrame(m));
  }

  function sendInput(bytes) {
    if (attached && ws && ws.readyState === WebSocket.OPEN) ws.send(inputFrame(attached, bytes));
  }

  function connect() {
    clearTimeout(retryTimer);
    setConn("connecting");
    ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
    ws.binaryType = "arraybuffer";
    ws.onopen = () => ws.send(JSON.stringify({ type: "auth", token }));
    ws.onmessage = (ev) => (typeof ev.data === "string" ? onText(JSON.parse(ev.data)) : onFrame(new Uint8Array(ev.data)));
    ws.onclose = (ev) => {
      ws = null;
      attached = null;
      pending.clear();
      if (ev.code === 4001) {
        store.set("token", null);
        token = null;
        showLogin(t("badToken"));
        return;
      }
      setConn("closed");
      retryTimer = setTimeout(connect, retryDelay);
      retryDelay = Math.min(retryDelay * 2, 10000);
    };
  }

  function onText(msg) {
    if (msg.type === "ready") {
      retryDelay = 1000;
      titles = msg.titles || {};
      showApp();
      setConn("open");
      send({ type: "list" }, (r) => {
        sessions.clear();
        for (const s of r.sessions || []) sessions.set(s.id, s);
        if (current && !sessions.has(current)) current = null;
        render();
        if (current) attach(current);
      });
    } else if (msg.type === "titles") {
      titles = msg.titles || {};
      render();
    }
  }

  function onFrame(b) {
    const kind = b[4];
    const payload = b.subarray(5);
    if (kind === KIND_OUTPUT) {
      if (bytesUUID(payload.subarray(0, 16)) === attached) term.write(payload.slice(16));
      return;
    }
    if (kind !== KIND_JSON) return;
    const msg = JSON.parse(decoder.decode(payload));
    if (msg.reqID != null && pending.has(msg.reqID)) {
      const cb = pending.get(msg.reqID);
      pending.delete(msg.reqID);
      cb(msg);
      return;
    }
    switch (msg.type) {
      case "sessions":
        for (const s of msg.sessions || []) sessions.set(s.id, s);
        // A new session's name is written by the app a moment later.
        setTimeout(() => ws && ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ type: "titles" })), 800);
        break;
      case "status": {
        const s = sessions.get(msg.id);
        if (!s) break;
        s.status = msg.status;
        s.permission = msg.permission || false;
        if (msg.exitCode != null) s.exitCode = msg.exitCode;
        if (msg.status === "exited") s.running = false;
        break;
      }
      case "removed":
        sessions.delete(msg.id);
        if (current === msg.id) select(null);
        break;
    }
    render();
  }

  // MARK: Sessions

  function select(id) {
    current = id;
    store.set("session", id);
    render();
    if (id) attach(id);
    else if (attached) { send({ type: "detach", id: attached }); attached = null; }
    $("app").dataset.view = id ? "terminal" : "list";
  }

  function attach(id) {
    if (attached && attached !== id) send({ type: "detach", id: attached });
    attached = id;
    $("terminal-card").hidden = false;
    $("empty").hidden = true;
    if (!termOpened) {
      term.open($("terminal"));
      termOpened = true;
    }
    term.reset();
    fit.fit();
    send({ type: "attach", id }, (r) => {
      if (r.error || attached !== id) return;
      // Same nudge as the app: full-screen programs repaint after the replay.
      send({ type: "resize", id, cols: Math.max(term.cols - 1, 2), rows: term.rows });
      setTimeout(() => attached === id && send({ type: "resize", id, cols: term.cols, rows: term.rows }), 150);
      if (!matchMedia("(pointer: coarse)").matches) term.focus();
    });
  }

  function name(s) {
    const meta = titles[s.id];
    if (meta && meta.title) return meta.title;
    return s.command ? s.command.split(/\s+/)[0] : t("shell");
  }
  function project(s) {
    const meta = titles[s.id];
    if (meta && meta.project) return meta.project;
    return s.cwd.split("/").filter(Boolean).pop() || "/";
  }

  function render() {
    const list = $("sessions");
    const live = [...sessions.values()].filter((s) => s.running || s.id === current);
    list.replaceChildren();
    if (live.length === 0) {
      const p = document.createElement("p");
      p.className = "none";
      p.textContent = t("noSessions");
      list.append(p);
    }
    const groups = new Map();
    for (const s of live.sort((a, b) => a.createdAt - b.createdAt)) {
      const key = project(s);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(s);
    }
    for (const [group, items] of groups) {
      const h = document.createElement("div");
      h.className = "group";
      h.textContent = group;
      list.append(h);
      for (const s of items) {
        const row = document.createElement("button");
        row.className = "row";
        row.setAttribute("aria-current", s.id === current ? "true" : "false");
        row.onclick = () => select(s.id);
        const dot = document.createElement("span");
        dot.className = "dot";
        dot.dataset.status = s.status;
        const text = document.createElement("span");
        text.className = "row-text";
        const title = document.createElement("span");
        title.className = "row-title";
        title.textContent = name(s);
        const sub = document.createElement("span");
        sub.className = "row-sub";
        sub.dataset.status = s.status;
        sub.textContent = t(s.status);
        text.append(title, sub);
        row.append(dot, text);
        list.append(row);
      }
    }

    const s = current && sessions.get(current);
    $("pane-name").textContent = s ? name(s) : "";
    $("pane-status").textContent = s ? `${t(s.status)} · ${project(s)}` : "";
    $("pane-dot").dataset.status = s ? s.status : "";
    $("pane-dot").hidden = !s;
    $("permission").hidden = !(s && s.permission);
    $("keys").hidden = !(s && matchMedia("(pointer: coarse)").matches);
    const pause = $("pause");
    pause.hidden = !(s && s.running);
    pause.textContent = s && s.status === "paused" ? t("resume") : t("pause");
    if (!s) {
      $("terminal-card").hidden = true;
      $("empty").hidden = false;
    }
    document.title = s ? `${name(s)} — Terminaly` : "Terminaly";
  }

  // MARK: UI

  function setConn(state) {
    const el = $("conn");
    el.dataset.state = state;
    el.title = state === "open" ? "" : t("reconnecting");
  }

  function showLogin(error) {
    $("app").hidden = true;
    $("login").hidden = false;
    $("login-error").hidden = !error;
    $("login-error").textContent = error || "";
    $("token").focus();
  }

  function showApp() {
    $("login").hidden = true;
    $("app").hidden = false;
    $("app").dataset.view = current ? "terminal" : "list";
    refit();
  }

  $("login-form").onsubmit = (ev) => {
    ev.preventDefault();
    token = $("token").value.trim();
    if (!token) return;
    store.set("token", token);
    $("token").value = "";
    connect();
  };
  $("logout").onclick = () => {
    store.set("token", null);
    token = null;
    if (ws) { ws.onclose = null; ws.close(); ws = null; }
    attached = null;
    showLogin();
  };
  $("back").onclick = () => select(null);
  $("allow").onclick = () => { sendInput(encoder.encode("\r")); term.focus(); };
  $("deny").onclick = () => { sendInput(encoder.encode("\x1b")); term.focus(); };
  $("pause").onclick = () => {
    const s = current && sessions.get(current);
    if (s) send({ type: s.status === "paused" ? "continue" : "pause", id: s.id });
  };
  const keys = { esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", ctrlc: "\x03", enter: "\r" };
  for (const b of $("keys").querySelectorAll("button")) {
    b.onclick = () => sendInput(encoder.encode(keys[b.dataset.key]));
  }
  // Back from a hidden tab: the socket may have died while the phone slept.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && token && !ws) connect();
  });

  if (token) connect();
  else showLogin();
})();

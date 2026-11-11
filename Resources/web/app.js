// Terminaly web client. Speaks the daemon's own frame protocol over a WebSocket:
// one binary message = one frame [UInt32 BE length][UInt8 kind][payload]. `tly web` authenticates
// the socket and filters requests. Starting sessions is a text command to the bridge ("start",
// "new"): the page names a saved session or a preset, and the bridge takes the command from the Mac.
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
      empty: "Pick a session.", noSessions: "No projects yet. Add one in Terminaly on the Mac.",
      permission: "Needs your permission", allow: "Allow", deny: "Deny", pause: "Pause", resume: "Resume",
      badToken: "That token is not valid.", reconnecting: "Reconnecting…",
      starting: "Starting", working: "Working", idle: "Ready", needsInput: "Needs input", paused: "Paused", exited: "Exited",
      stopped: "Stopped", shell: "Shell", workspace: "Workspace", allWorkspaces: "All workspaces",
      stoppedBar: "This session is stopped", startFresh: "Start Fresh", resumeConversation: "Resume Conversation",
      start: "Start", newSession: "New session", newIn: "New session in", startFailed: "Could not start the session",
      stoppedEmpty: "Start it again to keep working.",
    },
    es: {
      loginHelp: "Pega el token de acceso de Terminaly → Ajustes → Web de tu Mac.",
      tokenPlaceholder: "Token de acceso", connect: "Conectar", logout: "Cerrar sesión", sessions: "Sesiones",
      empty: "Elige una sesión.", noSessions: "Aún no hay proyectos. Añade uno en Terminaly en el Mac.",
      permission: "Necesita tu permiso", allow: "Permitir", deny: "Denegar", pause: "Pausar", resume: "Reanudar",
      badToken: "El token no es válido.", reconnecting: "Reconectando…",
      starting: "Arrancando", working: "Trabajando", idle: "Listo", needsInput: "Pide respuesta", paused: "En pausa", exited: "Terminado",
      stopped: "Detenida", shell: "Shell", workspace: "Espacio de trabajo", allWorkspaces: "Todos los espacios",
      stoppedBar: "Esta sesión está detenida", startFresh: "Empezar de cero", resumeConversation: "Reanudar conversación",
      start: "Iniciar", newSession: "Nueva sesión", newIn: "Nueva sesión en", startFailed: "No se ha podido iniciar la sesión",
      stoppedEmpty: "Iníciala de nuevo para seguir trabajando.",
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

  const live = new Map();     // id → SessionInfo from the daemon (running, or exited but not removed)
  let catalog = { workspaces: [], projects: [], presets: [], sessions: [] }; // from the app's state file
  let current = store.get("session");
  let workspace = store.get("workspace") || "";
  let attached = null;
  let ws = null;
  let token = null;
  let nextReq = 1;
  const pending = new Map();
  let retryDelay = 1000;
  let retryTimer = null;
  let catalogTimer = null;

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

  // Size for a session that starts before the terminal is on screen.
  function gridSize() {
    if (termOpened) return { cols: term.cols, rows: term.rows };
    const dims = fit.proposeDimensions();
    return dims && dims.cols ? dims : { cols: 120, rows: 32 };
  }

  // MARK: Connection

  const isOpen = () => ws && ws.readyState === WebSocket.OPEN;

  function send(msg, reply) {
    if (!isOpen()) return;
    const m = { ...msg, reqID: nextReq++ };
    if (reply) pending.set(m.reqID, reply);
    ws.send(jsonFrame(m));
  }

  function command(msg) {
    if (isOpen()) ws.send(JSON.stringify(msg));
  }

  function sendInput(bytes) {
    if (attached && isOpen() && live.get(attached)?.running) ws.send(inputFrame(attached, bytes));
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

  // The app writes new names and sessions to its state file a moment after they change.
  function refreshCatalogSoon() {
    clearTimeout(catalogTimer);
    catalogTimer = setTimeout(() => command({ type: "catalog" }), 800);
  }

  function onText(msg) {
    switch (msg.type) {
      case "ready":
        retryDelay = 1000;
        catalog = msg.catalog || catalog;
        showApp();
        setConn("open");
        send({ type: "list" }, (r) => {
          live.clear();
          for (const s of r.sessions || []) live.set(s.id, s);
          if (current && !known(current)) current = null;
          render();
          if (current) open(current);
        });
        break;
      case "catalog":
        catalog = msg.catalog || catalog;
        render();
        break;
      case "started":
        if (msg.error || !msg.id) {
          showError(`${t("startFailed")}: ${msg.error || "?"}`);
          break;
        }
        refreshCatalogSoon();
        select(msg.id, true);
        break;
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
        for (const s of msg.sessions || []) live.set(s.id, s);
        refreshCatalogSoon();
        break;
      case "status": {
        const s = live.get(msg.id);
        if (!s) break;
        s.status = msg.status;
        s.permission = msg.permission || false;
        if (msg.exitCode != null) s.exitCode = msg.exitCode;
        if (msg.status === "exited") { s.running = false; refreshCatalogSoon(); }
        break;
      }
      case "removed":
        live.delete(msg.id);
        refreshCatalogSoon();
        if (current === msg.id) open(current);
        break;
    }
    render();
  }

  // MARK: Model

  const saved = (id) => catalog.sessions.find((s) => s.id === id);
  const known = (id) => live.has(id) || !!saved(id);
  const isRunning = (id) => !!live.get(id)?.running;

  /// One row: the daemon's live state, the app's name and project.
  function view(id) {
    const info = live.get(id);
    const meta = saved(id);
    const running = !!info?.running;
    let title = meta?.title;
    if (!title) title = info?.command ? info.command.split(/\s+/)[0] : t("shell");
    return {
      id, title, running,
      status: running ? info.status : "stopped",
      permission: running && !!info.permission,
      projectID: meta?.projectID || null,
      cwd: info?.cwd || "",
      resumable: !!meta?.resumable,
      createdAt: meta?.createdAt ?? info?.createdAt ?? 0,
    };
  }

  function projectName(v) {
    const p = catalog.projects.find((p) => p.id === v.projectID);
    if (p) return p.name;
    return v.cwd.split("/").filter(Boolean).pop() || "/";
  }

  // MARK: Sessions

  function select(id, fromStart) {
    current = id;
    store.set("session", id);
    closeMenu();
    $("app").dataset.view = id ? "terminal" : "list";
    if (id) open(id, fromStart);
    else if (attached) { send({ type: "detach", id: attached }); attached = null; }
    render();
  }

  /// Shows a session: live ones attach; stopped ones show their last output if the Mac still has it.
  function open(id) {
    if (attached && attached !== id) send({ type: "detach", id: attached });
    attached = null;
    if (!live.has(id)) {
      $("terminal-card").hidden = true;
      $("empty").hidden = false;
      render();
      return;
    }
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
      if (!isRunning(id)) return;
      // Same nudge as the app: full-screen programs repaint after the replay.
      send({ type: "resize", id, cols: Math.max(term.cols - 1, 2), rows: term.rows });
      setTimeout(() => attached === id && send({ type: "resize", id, cols: term.cols, rows: term.rows }), 150);
      if (!matchMedia("(pointer: coarse)").matches) term.focus();
    });
  }

  function start(id, resume) {
    command({ type: "start", id, resume, ...gridSize() });
  }

  function newSession(projectID, presetID) {
    closeMenu();
    command({ type: "new", projectID, presetID, ...gridSize() });
  }

  // MARK: Rendering

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  const plusIcon = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';

  function renderWorkspaces() {
    const sel = $("workspace");
    const opts = [["", t("allWorkspaces")], ...catalog.workspaces.map((w) => [w.id, w.name])];
    if (workspace && !catalog.workspaces.some((w) => w.id === workspace)) workspace = "";
    sel.replaceChildren(...opts.map(([v, label]) => { const o = el("option", null, label); o.value = v; return o; }));
    sel.value = workspace;
    sel.parentElement.hidden = catalog.workspaces.length < 2;
  }

  function render() {
    renderWorkspaces();
    const list = $("sessions");
    list.replaceChildren();

    // Every saved session (not archived), plus live ones the app hasn't saved yet.
    const ids = new Set([...catalog.sessions.map((s) => s.id), ...[...live.values()].filter((s) => s.running).map((s) => s.id)]);
    const rows = [...ids].map(view);
    const byProject = new Map();
    for (const v of rows) {
      const key = v.projectID || `cwd:${v.cwd}`;
      if (!byProject.has(key)) byProject.set(key, []);
      byProject.get(key).push(v);
    }

    const groups = catalog.projects
      .filter((p) => !workspace || p.workspaceID === workspace)
      .map((p) => ({ id: p.id, name: p.name, items: byProject.get(p.id) || [] }));
    // Sessions started elsewhere whose folder is not a project yet.
    if (!workspace) {
      for (const [key, items] of byProject) {
        if (key.startsWith("cwd:")) groups.push({ id: null, name: projectName(items[0]), items });
      }
    }

    if (groups.length === 0) list.append(el("p", "none", t("noSessions")));
    for (const g of groups) {
      const head = el("div", "group");
      head.append(el("span", "group-name", g.name));
      if (g.id && catalog.presets.length) {
        const add = el("button", "icon-btn");
        add.innerHTML = plusIcon;
        add.setAttribute("aria-label", `${t("newIn")} ${g.name}`);
        add.title = t("newSession");
        add.setAttribute("aria-haspopup", "menu");
        add.onclick = (ev) => { ev.stopPropagation(); openMenu(add, g); };
        head.append(add);
      }
      list.append(head);
      // Running first, then stopped; each by creation.
      g.items.sort((a, b) => (b.running - a.running) || (a.createdAt - b.createdAt));
      for (const v of g.items) list.append(row(v));
    }

    const v = current && known(current) ? view(current) : null;
    $("pane-name").textContent = v ? v.title : "";
    $("pane-status").textContent = v ? `${t(v.status)} · ${projectName(v)}` : "";
    $("pane-dot").dataset.status = v ? (v.running ? v.status : "exited") : "";
    $("pane-dot").hidden = !v;
    $("permission").hidden = !(v && v.permission);
    $("keys").hidden = !(v && v.running && matchMedia("(pointer: coarse)").matches);
    $("stopped").hidden = !(v && !v.running && v.projectID);
    $("resume").hidden = !(v && v.resumable);
    $("restart").textContent = v && v.resumable ? t("startFresh") : t("start");
    $("restart").className = v && v.resumable ? "secondary" : "primary";
    $("empty-text").textContent = v && !v.running ? t("stoppedEmpty") : t("empty");
    const pause = $("pause");
    pause.hidden = !(v && v.running);
    pause.textContent = v && v.status === "paused" ? t("resume") : t("pause");
    if (!v) {
      $("terminal-card").hidden = true;
      $("empty").hidden = false;
    }
    document.title = v ? `${v.title} — Terminaly` : "Terminaly";
  }

  function row(v) {
    const r = el("button", "row");
    r.setAttribute("aria-current", v.id === current ? "true" : "false");
    r.dataset.stopped = String(!v.running);
    r.onclick = () => select(v.id);
    const dot = el("span", "dot");
    dot.dataset.status = v.running ? v.status : "exited";
    const text = el("span", "row-text");
    text.append(el("span", "row-title", v.title));
    const sub = el("span", "row-sub", t(v.status));
    sub.dataset.status = v.status;
    text.append(sub);
    r.append(dot, text);
    return r;
  }

  // MARK: New-session menu

  function openMenu(anchor, group) {
    const menu = $("menu");
    if (!menu.hidden && menu.dataset.project === group.id) return closeMenu();
    menu.dataset.project = group.id;
    menu.replaceChildren(el("div", "menu-label", `${t("newIn")} ${group.name}`));
    for (const p of catalog.presets) {
      const b = el("button", null, p.label || t("shell"));
      b.setAttribute("role", "menuitem");
      if (p.command) b.append(el("span", "cmd", p.command));
      b.onclick = () => newSession(group.id, p.id);
      menu.append(b);
    }
    menu.hidden = false;
    const r = anchor.getBoundingClientRect();
    const w = menu.offsetWidth, h = menu.offsetHeight;
    menu.style.left = `${Math.max(8, Math.min(r.left, innerWidth - w - 8))}px`;
    menu.style.top = `${r.bottom + h + 8 > innerHeight ? Math.max(8, r.top - h - 4) : r.bottom + 4}px`;
    menu.querySelector("button")?.focus();
  }

  function closeMenu() {
    $("menu").hidden = true;
    delete $("menu").dataset.project;
  }

  document.addEventListener("click", (ev) => { if (!$("menu").contains(ev.target)) closeMenu(); });
  document.addEventListener("keydown", (ev) => { if (ev.key === "Escape" && !$("menu").hidden) { closeMenu(); ev.preventDefault(); } });

  // MARK: UI

  function setConn(state) {
    const c = $("conn");
    c.dataset.state = state;
    c.title = state === "open" ? "" : t("reconnecting");
  }

  let errorTimer = null;
  function showError(text) {
    $("empty-text").textContent = text;
    clearTimeout(errorTimer);
    errorTimer = setTimeout(render, 4000);
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
  $("workspace").onchange = (ev) => {
    workspace = ev.target.value;
    store.set("workspace", workspace || null);
    render();
  };
  $("back").onclick = () => select(null);
  $("allow").onclick = () => { sendInput(encoder.encode("\r")); term.focus(); };
  $("deny").onclick = () => { sendInput(encoder.encode("\x1b")); term.focus(); };
  $("resume").onclick = () => current && start(current, true);
  $("restart").onclick = () => current && start(current, false);
  $("pause").onclick = () => {
    const s = current && live.get(current);
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

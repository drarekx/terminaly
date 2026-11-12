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
      open: "Open", restart: "Restart", stop: "Stop", continue: "Continue", moreActions: "More actions",
      expand: "Expand", collapse: "Collapse",
      resources: "Resources", resourcesHelp: "Sessions and resource usage", memory: "Memory",
      oneSession: "1 session", nSessions: "{n} sessions", runningPaused: "{r} running · {p} paused",
      noRunning: "No running sessions", host: "Session host (tly)",
      pauseIdle: "Pause idle sessions ({n})",
      resizedBar: "Sized for another screen", fitHere: "Fit Here",
      resourcesNote: "Pausing stops all CPU use and keeps the session as it is; its memory stays allocated. To free memory, stop the session: Claude conversations can be resumed later.",
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
      open: "Abrir", restart: "Reiniciar", stop: "Detener", continue: "Continuar", moreActions: "Más acciones",
      expand: "Desplegar", collapse: "Contraer",
      resources: "Recursos", resourcesHelp: "Sesiones y consumo de recursos", memory: "Memoria",
      oneSession: "1 sesión", nSessions: "{n} sesiones", runningPaused: "{r} en marcha · {p} en pausa",
      noRunning: "No hay sesiones en marcha", host: "Servicio de sesiones (tly)",
      pauseIdle: "Pausar sesiones inactivas ({n})",
      resizedBar: "Ajustado a otra pantalla", fitHere: "Ajustar aquí",
      resourcesNote: "Pausar detiene todo el uso de CPU y deja la sesión tal cual; la memoria sigue ocupada. Para liberarla, detén la sesión: las conversaciones de Claude se pueden reanudar después.",
    },
  };
  const lang = (navigator.languages || [navigator.language]).some((l) => /^(es|ca|gl|eu)\b/i.test(l)) ? "es" : "en";
  const t = (key, vars) => {
    let s = strings[lang][key] ?? strings.en[key] ?? key;
    for (const k in vars || {}) s = s.replace(`{${k}}`, vars[k]);
    return s;
  };
  document.documentElement.lang = lang;
  for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of document.querySelectorAll("[data-i18n-placeholder]")) el.placeholder = t(el.dataset.i18nPlaceholder);
  for (const el of document.querySelectorAll("[data-i18n-label]")) el.setAttribute("aria-label", t(el.dataset.i18nLabel));
  for (const el of document.querySelectorAll("[data-i18n-title]")) el.title = t(el.dataset.i18nTitle);

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
  // Project groups folded on this browser (project id, or "cwd:<folder>" for folders without a project).
  const collapsed = new Set((() => { try { return JSON.parse(store.get("collapsed") || "[]"); } catch { return []; } })());
  // Restart of a running session: stop it, then start it once the daemon reports the exit.
  const restartAfterExit = new Map(); // id → resume?

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

  // A session has one size, shared with the Mac app and other browsers. When another screen sets
  // it, this one follows (drawing output laid out for another size garbles it) until it is used again.
  let foreignSize = false;
  let adopting = false;

  function setForeign(on) {
    foreignSize = on;
    $("terminal-card").classList.toggle("foreign", on);
    $("resized").hidden = !on;
  }

  function adoptSize(cols, rows) {
    if (!termOpened || !cols || !rows) return;
    const own = fit.proposeDimensions();
    if (own && own.cols === cols && own.rows === rows) {
      if (foreignSize) setForeign(false);
    } else if (!foreignSize) {
      setForeign(true);
    }
    if (cols === term.cols && rows === term.rows) return;
    adopting = true;
    term.resize(cols, rows);
    adopting = false;
  }

  function reclaimSize() {
    if (!foreignSize) return;
    setForeign(false);
    fit.fit();  // differs from the adopted size, so onResize tells the daemon
  }

  term.onData((d) => { reclaimSize(); sendInput(encoder.encode(d)); });
  term.onBinary((d) => sendInput(Uint8Array.from(d, (c) => c.charCodeAt(0) & 0xff)));
  term.onResize(({ cols, rows }) => {
    if (attached && !adopting) send({ type: "resize", id: attached, cols, rows });
  });

  let fitTimer = null;
  function refit() {
    clearTimeout(fitTimer);
    fitTimer = setTimeout(() => {
      if (termOpened && !foreignSize && !$("terminal-card").hidden) fit.fit();
    }, 60);
  }
  new ResizeObserver(refit).observe($("terminal-card"));
  $("fit-here").onclick = () => { reclaimSize(); if (!matchMedia("(pointer: coarse)").matches) term.focus(); };

  // iOS keeps the page height when the keyboard opens and covers the last lines, where agents
  // put their prompt. Other browsers shrink the page themselves (interactive-widget).
  if (window.visualViewport) {
    visualViewport.addEventListener("resize", () => {
      const covered = visualViewport.height < innerHeight - 1;
      $("app").style.height = covered ? `${visualViewport.height}px` : "";
      if (covered) scrollTo(0, 0);
    });
  }

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
        pollStats();
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
        if (msg.status === "exited") {
          s.running = false;
          refreshCatalogSoon();
          if (restartAfterExit.has(msg.id)) {
            const resume = restartAfterExit.get(msg.id);
            restartAfterExit.delete(msg.id);
            start(msg.id, resume);
          }
        }
        break;
      }
      case "resized":
        if (msg.id === attached) adoptSize(msg.cols, msg.rows);
        return;
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
    let title = meta?.title || info?.title;
    if (!title) title = info?.command ? info.command.split(/\s+/)[0] : t("shell");
    return {
      id, title, running,
      status: running ? info.status : "stopped",
      permission: running && !!info.permission,
      projectID: meta?.projectID || null,
      // The session that started this one; the daemon knows before the app has saved it.
      parentID: meta?.parentID || info?.parent || null,
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
    setForeign(false);
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

  /// Ends the process but keeps the session, like "Stop" in the app: it can be started or resumed later.
  function stop(id) {
    restartAfterExit.delete(id);
    if (isRunning(id)) send({ type: "kill", id });
  }

  function restart(id, resume) {
    if (!isRunning(id)) return start(id, resume);
    restartAfterExit.set(id, resume);
    send({ type: "kill", id });
  }

  function togglePause(id) {
    const s = live.get(id);
    if (s?.running) send({ type: s.status === "paused" ? "continue" : "pause", id }, () => setTimeout(pollStats, 300));
  }

  // MARK: Rendering

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  const plusIcon = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
  const chevronIcon = '<svg class="chevron" viewBox="0 0 16 16" width="10" height="10" aria-hidden="true"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const moreIcon = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="3.5" cy="8" r="1.4" fill="currentColor"/><circle cx="8" cy="8" r="1.4" fill="currentColor"/><circle cx="12.5" cy="8" r="1.4" fill="currentColor"/></svg>';
  const pauseIcon = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><rect x="4" y="3" width="2.6" height="10" rx="0.8" fill="currentColor"/><rect x="9.4" y="3" width="2.6" height="10" rx="0.8" fill="currentColor"/></svg>';
  const playIcon = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M5 3.2v9.6a.6.6 0 0 0 .9.5l7.4-4.8a.6.6 0 0 0 0-1L5.9 2.7a.6.6 0 0 0-.9.5z" fill="currentColor"/></svg>';

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
      const key = g.id || `cwd:${g.items[0]?.cwd || g.name}`;
      const folded = collapsed.has(key);
      const head = el("div", "group");
      const toggle = el("button", "group-toggle");
      toggle.setAttribute("aria-expanded", String(!folded));
      toggle.title = folded ? t("expand") : t("collapse");
      toggle.innerHTML = chevronIcon;
      toggle.append(el("span", "group-name", g.name));
      if (folded) {
        // Folded: still show how many are running and whether one is waiting for you.
        const running = g.items.filter((v) => v.running);
        if (running.length) {
          const count = el("span", "group-count");
          if (running.some((v) => v.status === "needsInput")) {
            const d = el("span", "dot");
            d.dataset.status = "needsInput";
            count.append(d);
          }
          count.append(String(running.length));
          toggle.append(count);
        }
      }
      toggle.onclick = () => {
        if (folded) collapsed.delete(key); else collapsed.add(key);
        store.set("collapsed", JSON.stringify([...collapsed]));
        render();
      };
      head.append(toggle);
      if (g.id && catalog.presets.length) {
        const add = el("button", "icon-btn");
        add.innerHTML = plusIcon;
        add.setAttribute("aria-label", `${t("newIn")} ${g.name}`);
        add.title = t("newSession");
        add.setAttribute("aria-haspopup", "menu");
        add.onclick = (ev) => { ev.stopPropagation(); openPresetMenu(add, g); };
        head.append(add);
      }
      list.append(head);
      if (folded) continue;
      // Running first, then stopped; each by creation.
      g.items.sort((a, b) => (b.running - a.running) || (a.createdAt - b.createdAt));
      // Workers right under the session that started them, when it is in the same project.
      const inGroup = new Set(g.items.map((v) => v.id));
      const workersOf = (id) => g.items.filter((w) => w.parentID === id);
      for (const v of g.items) {
        if (v.parentID && inGroup.has(v.parentID) && v.parentID !== v.id) continue;
        list.append(row(v, workersOf(v.id)));
        for (const w of workersOf(v.id)) list.append(row(w, [], true));
      }
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
    renderUsage();
  }

  function row(v, workers = [], isWorker = false) {
    const wrap = el("div", isWorker ? "row-wrap worker" : "row-wrap");
    const r = el("button", "row");
    r.setAttribute("aria-current", v.id === current ? "true" : "false");
    r.dataset.stopped = String(!v.running);
    r.onclick = () => select(v.id);
    r.oncontextmenu = (ev) => {
      ev.preventDefault();
      openSessionMenu(v.id, { x: ev.clientX, y: ev.clientY });
    };
    const dot = el("span", "dot");
    dot.dataset.status = v.running ? v.status : "exited";
    const text = el("span", "row-text");
    text.append(el("span", "row-title", v.title));
    const sub = el("span", "row-sub", t(v.status));
    sub.dataset.status = v.status;
    text.append(sub);
    if (workers.length) {
      // "Needs input 1 · Working 3": what needs you first.
      const line = el("span", "row-sub row-workers");
      for (const status of ["needsInput", "working", "starting", "idle", "paused", "exited", "stopped"]) {
        const n = workers.filter((w) => w.status === status).length;
        if (!n) continue;
        if (line.childNodes.length) line.append(" · ");
        const part = el("span", null, `${t(status)} ${n}`);
        part.dataset.status = status;
        line.append(part);
      }
      text.append(line);
    }
    r.append(dot, text);

    const more = el("button", "icon-btn more");
    more.innerHTML = moreIcon;
    more.setAttribute("aria-label", `${t("moreActions")}: ${v.title}`);
    more.title = t("moreActions");
    more.setAttribute("aria-haspopup", "menu");
    more.setAttribute("aria-expanded", String(menuOwner === `s:${v.id}`));
    more.onclick = (ev) => { ev.stopPropagation(); openSessionMenu(v.id, more); };
    wrap.append(r, more);
    return wrap;
  }

  // MARK: Menus

  /// The same actions as the session menu in the app, minus the ones that only make sense there.
  function sessionActions(id) {
    const v = view(id);
    const items = [];
    if (id !== current) items.push({ label: t("open"), run: () => select(id) });
    if (v.running) {
      items.push({ label: v.status === "paused" ? t("continue") : t("pause"), run: () => togglePause(id) });
      if (v.projectID) items.push({ label: t("restart"), run: () => restart(id, false) });
      items.push("-", { label: t("stop"), danger: true, run: () => stop(id) });
    } else if (v.projectID) {
      if (v.resumable) items.push({ label: t("resumeConversation"), run: () => { select(id); start(id, true); } });
      items.push({ label: v.resumable ? t("startFresh") : t("start"), run: () => { select(id); start(id, false); } });
    }
    return items;
  }

  let menuOwner = null;

  /// `at` is an element (menu below it) or a point (context menu).
  function showMenu(owner, label, items, at) {
    const menu = $("menu");
    if (!menu.hidden && menuOwner === owner && at instanceof Element) return closeMenu();
    menuOwner = owner;
    menu.replaceChildren();
    if (label) menu.append(el("div", "menu-label", label));
    for (const item of items) {
      if (item === "-") { menu.append(el("hr")); continue; }
      const b = el("button", item.danger ? "danger" : null, item.label);
      b.setAttribute("role", "menuitem");
      if (item.detail) b.append(el("span", "cmd", item.detail));
      b.onclick = (ev) => { ev.stopPropagation(); closeMenu(); item.run(); };
      menu.append(b);
    }
    menu.hidden = false;
    const w = menu.offsetWidth, h = menu.offsetHeight;
    let x, y;
    if (at instanceof Element) {
      const r = at.getBoundingClientRect();
      x = r.left;
      y = r.bottom + h + 8 > innerHeight ? r.top - h - 4 : r.bottom + 4;
      at.setAttribute("aria-expanded", "true");
    } else {
      x = at.x;
      y = at.y + h + 8 > innerHeight ? at.y - h : at.y;
    }
    menu.style.left = `${Math.max(8, Math.min(x, innerWidth - w - 8))}px`;
    menu.style.top = `${Math.max(8, y)}px`;
    menu.querySelector("button")?.focus();
  }

  function openSessionMenu(id, at) {
    const items = sessionActions(id);
    if (items.length) showMenu(`s:${id}`, view(id).title, items, at);
  }

  function openPresetMenu(anchor, group) {
    showMenu(`p:${group.id}`, `${t("newIn")} ${group.name}`,
      catalog.presets.map((p) => ({ label: p.label || t("shell"), detail: p.command, run: () => newSession(group.id, p.id) })),
      anchor);
  }

  function closeMenu() {
    $("menu").hidden = true;
    menuOwner = null;
    for (const b of document.querySelectorAll('[aria-haspopup="menu"][aria-expanded="true"]')) b.setAttribute("aria-expanded", "false");
  }

  document.addEventListener("click", (ev) => {
    if (!$("menu").contains(ev.target)) closeMenu();
    if (!$("resources").hidden && !$("resources").contains(ev.target) && !$("usage-btn").contains(ev.target)) toggleResources(false);
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key !== "Escape") return;
    if (!$("menu").hidden) { closeMenu(); ev.preventDefault(); }
    else if (!$("resources").hidden) { toggleResources(false); ev.preventDefault(); }
  });
  // Scrolling the list moves the rows away from a menu opened on them.
  $("sessions").addEventListener("scroll", closeMenu, { passive: true });

  // MARK: Resources

  let usage = new Map();   // id → { memory, cpu, processes }
  let hostUsage = null;
  const lastCPU = new Map(); // id or "host" → { time (ns), at (ms) }
  let statsTimer = null;

  const resourcesOpen = () => !$("resources").hidden;
  const nf = (digits) => new Intl.NumberFormat(lang, { minimumFractionDigits: digits, maximumFractionDigits: digits });
  function fmtMemory(bytes) {
    const mb = bytes / 1048576;
    return mb >= 1024 ? `${nf(1).format(mb / 1024)} GB` : `${nf(0).format(mb)} MB`;
  }
  const fmtCPU = (cpu) => (cpu == null ? "–" : `${Math.round(cpu)} %`);

  /// CPU % from the change in CPU time between two samples, like ResourceMonitor in the app.
  function sample(key, u, now) {
    const prev = lastCPU.get(key);
    let cpu = null;
    if (prev && now - prev.at > 100) cpu = Math.max(0, u.cpuTime - prev.time) / 1e6 / (now - prev.at) * 100;
    lastCPU.set(key, { time: u.cpuTime, at: now });
    return { memory: u.memory, cpu, processes: u.processes };
  }

  /// Samples only while the page is visible: every 10 s for the footer, every 2 s with the panel open.
  function pollStats() {
    clearTimeout(statsTimer);
    if (!isOpen() || document.visibilityState !== "visible") return;
    send({ type: "stats" }, (r) => {
      if (r.error) return;
      const now = performance.now();
      const next = new Map();
      const seen = new Set(["host"]);
      for (const e of r.usage || []) { next.set(e.id, sample(e.id, e.usage, now)); seen.add(e.id); }
      for (const k of lastCPU.keys()) if (!seen.has(k)) lastCPU.delete(k);
      usage = next;
      hostUsage = r.hostUsage ? sample("host", r.hostUsage, now) : null;
      renderUsage();
    });
    statsTimer = setTimeout(pollStats, resourcesOpen() ? 2000 : 10000);
  }

  function totals() {
    let memory = hostUsage?.memory || 0, cpu = hostUsage?.cpu ?? null;
    for (const u of usage.values()) {
      memory += u.memory;
      if (u.cpu != null) cpu = (cpu || 0) + u.cpu;
    }
    return { memory, cpu };
  }

  function renderUsage() {
    const running = [...live.values()].filter((s) => s.running);
    const { memory, cpu } = totals();
    const n = running.length;
    $("usage-summary").textContent =
      `${n === 1 ? t("oneSession") : t("nSessions", { n })} · ${fmtMemory(memory)} · CPU ${fmtCPU(cpu)}`;
    if (!resourcesOpen()) return;

    const paused = running.filter((s) => s.status === "paused").length;
    $("resources-count").textContent = t("runningPaused", { r: n, p: paused });
    $("total-mem").textContent = fmtMemory(memory);
    $("total-cpu").textContent = fmtCPU(cpu);

    const rows = $("usage-rows");
    rows.replaceChildren();
    if (!n) rows.append(el("p", "none", t("noRunning")));
    running.sort((a, b) => (usage.get(b.id)?.memory || 0) - (usage.get(a.id)?.memory || 0));
    for (const s of running) {
      const v = view(s.id);
      const u = usage.get(s.id);
      const r = el("div", "usage-row");
      r.dataset.clickable = "";
      r.onclick = () => { toggleResources(false); select(s.id); };
      const dot = el("span", "dot");
      dot.dataset.status = v.status;
      const text = el("span", "row-text");
      text.append(el("span", "row-title", v.title), el("span", "row-sub", projectName(v)));
      const pause = el("button", "icon-btn");
      pause.innerHTML = v.status === "paused" ? playIcon : pauseIcon;
      const label = v.status === "paused" ? t("continue") : t("pause");
      pause.setAttribute("aria-label", `${label}: ${v.title}`);
      pause.title = label;
      pause.onclick = (ev) => { ev.stopPropagation(); togglePause(s.id); };
      r.append(dot, text, el("span", "num mem", u ? fmtMemory(u.memory) : "–"), el("span", "num cpu", fmtCPU(u?.cpu)), pause);
      rows.append(r);
    }
    rows.append(el("hr", "usage-sep"));
    const h = el("div", "usage-row");
    const hostText = el("span", "row-text");
    hostText.append(el("span", "row-title", t("host")));
    h.append(el("span"), hostText, el("span", "num mem", hostUsage ? fmtMemory(hostUsage.memory) : "–"),
      el("span", "num cpu", fmtCPU(hostUsage?.cpu)), el("span"));
    rows.append(h);

    const idle = running.filter((s) => s.status === "idle");
    const pi = $("pause-idle");
    pi.hidden = !idle.length;
    pi.textContent = t("pauseIdle", { n: idle.length });
    pi.onclick = () => { for (const s of idle) togglePause(s.id); };
  }

  function toggleResources(show = !resourcesOpen()) {
    $("resources").hidden = !show;
    $("usage-btn").setAttribute("aria-expanded", String(show));
    if (show) { closeMenu(); renderUsage(); }
    pollStats();
  }
  $("usage-btn").onclick = (ev) => { ev.stopPropagation(); toggleResources(); };

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
  $("pause").onclick = () => current && togglePause(current);
  const keys = { esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", ctrlc: "\x03", enter: "\r" };
  for (const b of $("keys").querySelectorAll("button")) {
    b.onclick = () => sendInput(encoder.encode(keys[b.dataset.key]));
  }
  // Back from a hidden tab: the socket may have died while the phone slept.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    if (token && !ws) connect();
    else pollStats();
  });

  if (token) connect();
  else showLogin();
})();

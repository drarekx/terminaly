# Terminaly

App nativa de macOS para lanzar y vigilar sesiones de agentes CLI (Claude Code, Codex, shells), inspirada en Unpeel. Repo público: https://github.com/drarekx/terminaly. Plan de trabajo en `ROADMAP.md`: márcalo al completar elementos. Mantén este archivo al día cuando cambie la arquitectura, el flujo de release o aparezca una trampa nueva.

## Estructura

SwiftPM, macOS 14+, Swift 6 toolchain en modo de lenguaje 5 (`swiftLanguageMode(.v5)` en todos los targets).

| Target | Qué es |
|---|---|
| `Terminaly` | App SwiftUI. Renderiza terminales (SwiftTerm `TerminalView`), no es dueña de ningún proceso. |
| `tly` | Daemon de sesiones (`tly daemon`, se arranca solo) + CLI (`tly ls/new/send/ask/result/logs/attach/wait/kill/rm/shutdown`) + puente web (`tly web`). |
| `TerminalyKit` | Protocolo compartido: framing, `Message`, sockets Unix, lanzador del daemon, rutas, `Git` (worktrees; lo usan la app y la CLI). |

Dependencias: SwiftTerm (terminal), Sparkle 2 (auto-update). Nada más.

### Daemon `tly` (`Sources/tly`)
- Un solo proceso para todas las sesiones. PTYs con `forkpty` (`Pty.swift`); todo en una cola serie con DispatchSources (kqueue): cero CPU en reposo, sin polling salvo un timer de 30 s.
- Ring buffer de 2 MB por sesión para replay al hacer `attach`.
- Servidor HTTP de hooks en `127.0.0.1:<puerto aleatorio>` con token por ejecución (`HookServer.swift`). Las sesiones reciben `TERMINALY_SESSION_ID`, `TERMINALY_HOOK_PORT`, `TERMINALY_HOOK_TOKEN`.
- El estado (`starting/working/idle/needsInput/exited`) se calcula en el daemon (`HostedSession`): por hooks si la sesión los envía, si no por actividad de salida (working mientras sale texto, idle tras 2 s). Solo notifica sesiones con hooks.
- Pausa (`pause`/`continue`, `tly pause/resume`): SIGSTOP/SIGCONT a todo el árbol de procesos por ppid (los agentes meten ayudantes, p. ej. servidores MCP, en otros grupos), padres antes que hijos al parar y al revés al continuar, para que la shell no vea el job parado y recupere el terminal. Libera CPU, no memoria; para liberar memoria se detiene la sesión y se reanuda con `claude --resume`. Estado `paused`; se ignoran hooks mientras dura.
- Consumo: `stats` devuelve memoria (`ri_phys_footprint`) y tiempo de CPU de cada árbol de sesión y del daemon (`TerminalyKit/ProcessStats.swift`, libproc). El % de CPU lo calcula la app entre muestras (`Model/ResourceMonitor.swift`), que solo muestrea mientras una vista lo muestra y la app está activa: pie de la barra lateral (10 s) y popover de recursos (2 s).
- Se cierra solo tras 60 s sin sesiones vivas ni clientes.
- Socket: `~/Library/Application Support/Terminaly/tly.sock`, permisos 0600, solo acepta peers con el mismo UID.

### Swarm (workers)
Plan en `ROADMAP.md` (v0.6). Terminaly no orquesta: el «jefe» es una sesión normal que usa `tly`.
- **Padre**: `tly new` lee `TERMINALY_SESSION_ID` y lo manda como `parent` (`--no-parent` lo evita). El daemon rechaza el `create` si el padre ya es worker (profundidad 1) o ha llegado al límite de workers vivos. Un padre que el daemon no conoce se ignora.
- **Límite**: `DaemonConfig` (TerminalyKit) → `daemon.json` del `stateDir`, que edita Ajustes → Agentes (1–16, por defecto 6). El daemon lo lee en cada `create` con padre (archivo pequeño, solo ahí), así vale para un daemon ya en marcha y con la app cerrada. `TERMINALY_MAX_WORKERS` en el entorno del daemon gana al archivo.
- **Prompt inicial** (`--prompt`): el daemon lo añade al comando como argumento entre comillas (`HostedSession.shellQuote`); `SessionInfo.command` sigue siendo el comando limpio (los presets se reconocen por él). Con `opencode` va tras `--prompt` (`promptFlag`): su argumento posicional es una carpeta. La sesión nace en `working` y `SessionStart` no la pasa a `idle` hasta su primer `Stop`: así `tly wait` no vuelve antes de que responda.
- **Turnos** (`turns`): +1 en cada `Stop` (o al pasar a `idle` por la heurística). `send` responde con el contador; `tly ask` espera un evento `status` con `turns` mayor, no el estado (que tras un `send` sigue en `idle` hasta que llega `UserPromptSubmit`). `ask` se niega si la sesión está `working`: acabaría antes el turno en curso.
- **Resultado** (`result`, petición aparte para no engordar `list`): `last_assistant_message` del hook `Stop`; si no viene, el último texto del asistente en `transcript_path`, leído fuera de la cola del daemon. Sin hooks: la salida del turno sin secuencias de escape (hasta 256 KB; trae el eco y el prompt de la shell).
- **Enter aparte**: `send` con `enter` escribe el texto y, 100 ms después, el `\r`. Juntos, las TUI de agentes lo toman por un pegado y el Enter queda como salto de línea.
- **Worktree desde la CLI** (`--worktree rama`): lo crea la CLI (git nunca en la cola del daemon) en el repo principal (`Git.mainRepository`, también si se lanza desde otro worktree), con la rama nueva partiendo del commit de la carpeta desde la que se lanza (un jefe en su propio worktree pasa su trabajo), y manda `projectPath` y `branch`. `AppStore.adopt` los usa: sin ellos, una carpeta de worktree se adoptaba como proyecto nuevo.
- App: `Session.parentID` y `workersCollapsed` (persistidos). `AppStore.workers(of:)` solo cuenta los del mismo proyecto y no archivados; `sidebarSessions(in:)` da el orden de la barra lateral (cada sesión y debajo sus workers) y es también el orden de ⌘ siguiente/anterior. La fila del jefe (`SessionRow`) lleva el resumen por estado, que es el botón de plegar.
- «Ver swarm» (`showSwarm`) sustituye el layout del workspace por una rejilla con el jefe y sus workers. «Quitar workers terminados» (`removeFinishedWorkers`): `idle`, `exited` o parados; quita primero el worktree sin forzar y, si falla, deja la sesión tal cual. Un worktree que comparte otra sesión no se toca.
- Web: `parentID` en el catálogo y `parent` del daemon para las que la app aún no ha guardado; mismo anidado y resumen, sin plegar.
- `tly wait` y `tly ask` van por eventos (`SyncConnection.nextFrame(before:)`), sin polling. Código de salida de `ask`: 0 respondió, 2 pide respuesta (permiso), 3 tiempo agotado.
- **Skill** `terminaly-swarm` (`Hooks/SwarmSkill.swift`, texto dentro del binario): Ajustes → Agentes la escribe en `~/.claude/skills/terminaly-swarm/SKILL.md` (`CLAUDE_CONFIG_DIR` si está). Estado `missing/outdated/current` comparando el contenido: al cambiar el texto, la app ofrece «Actualizar». Si cambias la CLI de swarm, actualiza la skill.
- Las sesiones llevan la carpeta de `tly` al final del `PATH`: la skill funciona aunque no exista el enlace en `/opt/homebrew/bin`.
- **opencode** (probado con v2.2.0 el 2026-11-12): lee `~/.claude/skills`, así que ve la skill sin instalar nada. Estado, permisos y respuesta del turno llegan por el plugin de `Hooks/OpenCodePlugin.swift` (ver App).
- Paso 9 del self-test (también el límite y la instalación de la skill, en carpeta temporal).

### Acceso web (`tly web`, `Sources/tly/WebServer.swift`)
- Proceso aparte del daemon (un fallo o un navegador lento no puede parar la cola de las sesiones). Sirve `Resources/web` (copiado al `.app` por `bundle.sh`; en desarrollo lo busca subiendo desde el ejecutable) y un WebSocket en `/ws`, en `0.0.0.0:<puerto>` (7878 por defecto). Solo red local/VPN: HTTP sin TLS.
- Config en `web.json` del `stateDir` (0600: `enabled`, `port`, `token`), pid en `web.pid`, lock en `web.lock`, log en `tly-web.log`. La app (`Model/WebAccess.swift`, Ajustes → Web) edita el archivo y relanza el proceso con `DaemonLauncher.spawnDetached`; al arrancar la app lo reinicia si está activado para que sirva los archivos nuevos. Sigue vivo al cerrar la app.
- Cada pestaña del navegador abre su propia conexión al daemon, solo tras autenticarse (primer mensaje de texto `{"type":"auth","token":…}`; fallo = cierre 4001). Después, cada mensaje binario es exactamente un frame del protocolo del daemon en ambos sentidos. Se filtran las peticiones (`WebServer.allowedRequests`): `kill` (Detener: mata el proceso y la sesión queda para reanudarla) y `stats` sí; `create` solo por los comandos del puente; `remove/shutdown` nunca desde la web.
- Se comprueba `Origin` contra `Host` (otra web abierta en el mismo navegador no puede conectarse).
- Catálogo (espacios, proyectos, presets y sesiones guardadas, también las paradas) leído de `state.json` en cada petición (`AppStateFile`): el daemon solo conoce las sesiones vivas. Mensajes de texto del navegador: `catalog`, `start {id, resume}` y `new {projectID, presetID}`. El puente saca comando y carpeta del `state.json` (nunca de la página) y manda `create` al daemon con `reqID` negativo; la respuesta no se reenvía, se convierte en `started`. `AgentResume` (TerminalyKit) es el mismo `claude --resume` que usa la app.
- La app adopta al vuelo las sesiones que crea otro (evento `sessions` en `TerminalRegistry.handle` → `AppStore.adopt`): proyecto por carpeta, nombre por preset. Las que crea ella misma van en `starting` hasta la respuesta, porque el evento llega antes. Si la app está cerrada, las adopta al conectarse.
- Tamaño: el navegador redimensiona el PTY al conectarse; al volver a la app (`applicationDidBecomeActive`) los terminales visibles reclaman su tamaño (`reassertSizes`). Una sesión tiene un solo tamaño para todas las pantallas: el daemon avisa a los demás clientes conectados a esa sesión con el evento `resized`. El navegador lo adopta (`adoptSize`: pinta con ese tamaño y la tarjeta hace scroll; si no, el texto sale descolocado y la última línea, donde escriben los agentes, queda fuera) y muestra «Ajustado a otra pantalla · Ajustar aquí»; reclama su tamaño al escribir o con el botón. La app no lo adopta: sigue reclamando al activarse.
- Teclado en iOS: Safari no encoge la página (`interactive-widget` no le afecta); `app.js` ajusta la altura de `.app` a `visualViewport`. Sin probar en un iPhone real.
- Cliente: proyectos plegables (guardado en `localStorage` del navegador, no en `state.json`), menú de sesión con clic derecho o «…» (Pausar/Continuar, Reiniciar = `kill` y `start` al llegar el `exited`, Detener, Reanudar/Iniciar) y pie de recursos con `stats` (10 s; 2 s con el panel abierto; solo con la pestaña visible; % de CPU calculado entre muestras como `ResourceMonitor`).
- Cliente: `Resources/web/app.js` (sin build, JS plano) + xterm.js 5.5.0 y addon-fit 0.10.0 copiados de npm (licencia MIT en `LICENSE-xterm`). Textos en/es en el propio `app.js`.
- Probar: `TERMINALY_STATE_DIR` temporal con un `web.json` (`enabled: true`, puerto libre, token de prueba), `tly new`, `tly web`, y abrir `http://127.0.0.1:<puerto>/#token=<token>`.

### Protocolo (`TerminalyKit/Protocol.swift`)
Frames `[UInt32 BE longitud][UInt8 tipo][payload]`. Tipos: `json` (un `Message` plano con `type`), `output`/`input` (16 bytes de UUID + bytes crudos). Peticiones con `reqID`, eventos sin él (`sessions`, `status`, `removed`). Si cambias el protocolo, sube `protocolVersion`: tras una actualización puede quedar corriendo un daemon antiguo.

### App (`Sources/Terminaly`)
- `Model/AppStore.swift`: estado único `@Observable` (workspaces, proyectos, sesiones, presets, layout de paneles). Persistencia en `state.json` (escritura con debounce de 400 ms). Los campos nuevos de `PersistedState` deben ser opcionales o con `decodeIfPresent`: hay usuarios con archivos antiguos (ver migración a workspace "Personal" en `load()`).
- `Terminal/DaemonClient.swift` + `TerminalRegistry.swift`: conexión asíncrona al daemon en main queue; un `AgentTerminalView` por sesión, reutilizado y re-parentado (`TerminalContainer`).
- Workspaces: cada uno tiene nombre, icono, color y su propio `PaneNode` (árbol de splits). El layout vivo está en `store.layout` y se vuelca al workspace con `commitLayout()` al cambiar o guardar.
- Permisos: el daemon marca `permissionPending` con `PermissionRequest` (o una `Notification` que hable de "permission") y lo limpia con cualquier evento de trabajo/parada. `respondToPermission` envía Enter (acepta la opción marcada, "Sí") o Esc al PTY, solo si hay permiso pendiente. La barra va debajo del terminal, nunca encima: el diálogo del agente está en sus últimas líneas.
- Worktrees: `Model/Git.swift` (git en segundo plano). Sesión con `worktreePath` + `branch` (persistidos); la shell arranca en `workingDirectory(for:)`. Carpeta hermana `<repo>.worktrees/<rama>` para no ensuciar el repo. Quitar = `git worktree remove` sin forzar (falla con cambios sin commit) y la rama se conserva. Solo se ofrece en proyectos git (`store.gitProjects`). Paso 7 del self-test.
- Reanudar: los hooks traen `session_id`; se guarda en `Session.agentSessionID` (persistido) y `resumeCommand` = `claude --resume <id saneado>`.
- Cambios en el daemon solo llegan cuando se reinicia `tly` (al quedarse sin sesiones ni clientes, o `tly shutdown`): los campos nuevos del protocolo deben ser opcionales para convivir con un daemon antiguo.
- Plugin de opencode 2: `Hooks/OpenCodePlugin.swift` (archivos dentro del binario) → `~/.config/opencode/plugins/terminaly/` (`XDG_CONFIG_HOME` si está), desde Ajustes → Agentes. Es un paquete con parte servidor vacía (para que se cargue solo) y parte TUI (`@opencode/plugin/tui`), que es la que trabaja: corre en el proceso de la sesión y ve `TERMINALY_*`; el servidor de opencode es un servicio en segundo plano compartido por todas las ventanas y no ve ese entorno. Por lo mismo `ctx.data.listen` recibe eventos de todas las sesiones: solo cuentan los de la sesión abierta en esa TUI (`ctx.ui.router.current()`). Traduce a los mismos eventos que los hooks de Claude: `SessionStart` al cargar (sin él la heurística cuenta turnos durante el arranque), `session.execution.started` → `UserPromptSubmit`, `session.text.ended` guarda el texto, `session.execution.succeeded/failed/interrupted` → `Stop` con `last_assistant_message`, `permission.asked/replied` → `PermissionRequest`/`PostToolUse`. Enter acepta su diálogo de permiso («Allow once»), como en Claude. Reanudar: `opencode --session <id>` (`AgentResume`). Para probarlo aislado: `XDG_CONFIG_HOME` temporal con una copia de `opencode.jsonc`; para probar permisos, `opencode --standalone` (si no, manda la config del servicio ya arrancado). Tipos de la API: paquetes npm `@opencode/plugin` y `@opencode/client`.
- Hooks de Claude Code: `Hooks/HookInstaller.swift` escribe en `~/.claude/settings.json` (con backup `.terminaly-backup`); las entradas se reconocen por contener `TERMINALY_SESSION_ID`.

## Diseño ("Graphite")

Canvas: https://claude.ai/artifact/NXCTs7pMK3XnPDpKTfmoPY. Tokens en `UI/Theme.swift`; no inventes colores sueltos en las vistas.
- App siempre oscura (`preferredColorScheme(.dark)`). Fondo `0x0B0C0E`, tarjeta de terminal `0x0F1013`, texto `0xECECF1`.
- Barra lateral: mezcla sólida del 20 % del color del workspace sobre grafito (`Theme.sidebar`), sin degradados.
- El color del workspace (`store.accent`) marca foco, selección y botón principal. Los colores de estado (azul/verde/ámbar/violeta de pausa/gris en `SessionStatus.dot/text/tile`) son solo para agentes.
- Tipografía: solo `Theme.Font` (12 pt mínimo para texto legible); texto secundario `Theme.secondaryText`/`tertiaryText`.
- Botones: `PrimaryButtonStyle` (una acción principal por zona), `SecondaryButtonStyle`, `IconButtonStyle` (+ `.help`/`.accessibilityLabel`). El color del workspace llega por `@Environment(\.workspaceAccent)`: `Color.accentColor` ignora `.tint`. Los popovers viven en otra ventana; `PopoverMenuButton` les pasa el acento.
- Menús frecuentes = `PopoverMenu` + `MenuRow`/`MenuSectionLabel`/`ColorSwatchRow`/`SymbolGrid`; los menús contextuales (clic derecho) siguen nativos.
- Temas de terminal en `Terminal/TerminalTheme.swift` (`installColors` + fondo/texto/cursor); el fondo de la tarjeta del panel sigue al tema.

## Idioma

- Inglés es el idioma de desarrollo (las claves son el texto en inglés). Traducción en `Resources/es.lproj/Localizable.strings`; `bundle.sh` copia `Resources/*.lproj` al `.app`. Hace falta `en.lproj` aunque esté vacío, o un sistema en inglés recibe español.
- Todo texto visible debe ser `LocalizedStringKey` (literal en `Text`/`Button`/`.help`, `MenuRow(title:)`) o `String(localized:)`. Un ternario de literales o un `String` concatenado NO se traduce: usa `LocalizedStringKey(...)` explícito o `if/else`.
- Al añadir textos, extrae las claves y traduce las que falten: `swift build --product Terminaly -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>` genera `.stringsdata` (JSON) por archivo.
- Selector en Ajustes → General (`AppLanguage`: escribe `AppleLanguages` del dominio de la app y relanza). Probar sin tocar ajustes: pasar `-AppleLanguages "(es)"` al ejecutable. El sistema del autor está en catalán con español detrás, así que "Sistema" muestra español.

## Marca e icono

- Fuente de verdad: `brand/icon.svg` (y `icon-small.svg` para ≤32 px). `scripts/make-icon.sh` genera `Resources/AppIcon.icns` (lo copia `bundle.sh`; `CFBundleIconFile` = `AppIcon`) y `brand/icon-1024.png`. No edites el `.icns` a mano.
- Logotipos y banner: `brand/src/*.html` → PNG con `scripts/tools/render-html.swift` (WebKit, carga JetBrains Mono de Google Fonts). Detalles en `brand/README.md`.

## Comandos

```sh
swift build                                   # debug
./scripts/bundle.sh [release|debug]           # → build/Terminaly.app (incluye tly y Sparkle.framework)
TERMINALY_STATE_DIR=$(mktemp -d) .build/debug/Terminaly --selftest   # test end-to-end, debe imprimir SELFTEST PASS
TERMINALY_STATE_DIR=<dir con state.json> TERMINALY_SNAPSHOT_DIR=<out> build/Terminaly.app/Contents/MacOS/Terminaly
                                              # renderiza la ventana a PNG (un archivo por workspace, máx 3) + menus.png
                                              # extra: TERMINALY_SNAPSHOT_SHELL='cmd' abre una shell real; TERMINALY_SETTINGS_TAB=terminal|general captura Ajustes;
                                              # TERMINALY_SNAPSHOT_SWARM=1 abre «Ver swarm» de la primera sesión con workers;
                                              # TERMINALY_CLICK_AT=x,y simula un clic (puntos desde arriba-izquierda) y guarda after-click.png
                                              # (y popover.png si abre un popover; sale con fondo transparente)
./scripts/release.sh 0.3.0 "notas"            # publica release + appcast (ver abajo)
```

- **Verifica siempre con `--selftest`** antes de commitear cambios en store, daemon o protocolo. Cubre: workspaces (y migración si `SELFTEST_EXPECT_LEGACY_PROJECTS=N`), hooks → needsInput, heurística working → idle, reinicio simulado de la app con replay, pausa (paso 8: CPU parada y reanudada) y swarm (paso 9: worker adoptado bajo su padre, prompt inicial, resultado del turno).
- Para cambios visuales usa el modo snapshot: no hay permiso de grabación de pantalla, pero la app se pinta a sí misma (`cacheDisplay`). Siembra un `state.json` de prueba en un directorio temporal; nunca uses el estado real del usuario.
- Usa siempre `TERMINALY_STATE_DIR` en pruebas: si no, tocarías `~/Library/Application Support/Terminaly` (datos reales y el daemon real).

## Release y auto-update

- Sparkle lee `https://github.com/drarekx/terminaly/releases/latest/download/appcast.xml`. `release.sh` compila, firma el zip con la clave EdDSA del llavero (`sign_update`), genera el appcast, crea el tag, hace push y publica la release con `gh` (zip versionado, `Terminaly.zip` para el instalador y `appcast.xml`).
- `CFBundleVersion` = número de commits (`git rev-list --count HEAD`); `CFBundleShortVersionString` = archivo `VERSION`.
- Firma de código ad-hoc (no hay Developer ID). Sparkle acepta el cambio de firma porque la clave EdDSA es la misma; **no cambies `SUPublicEDKey`** o las copias instaladas dejarán de actualizarse. La clave privada solo está en el llavero de macOS del autor.
- Instalador: `curl -fsSL https://raw.githubusercontent.com/drarekx/terminaly/main/install.sh | bash` (instala en /Applications, enlaza `tly`, quita la cuarentena). Variables de prueba: `TERMINALY_ZIP_URL`, `TERMINALY_INSTALL_DIR`, `TERMINALY_BIN_DIR`, `TERMINALY_NO_OPEN`.
- Errores de actualización: Sparkle solo dice "ocurrió un error"; `UpdateDiagnostics` escribe la causa (con errores encadenados y URL) en `~/Library/Logs/Terminaly/update.log` (botón en Ajustes → General). Probado el 2026-10-14: la descarga de 0.4.0 → 0.4.1 funciona en el Mac del autor; un fallo de descarga en otra máquina apunta a su red o caché.
- Probar una actualización sin tocar la instalación real: bajar una release vieja a una carpeta temporal, cambiar `CFBundleIdentifier` (p. ej. `.updtest`), re-firmar ad-hoc, `defaults write <id> SUAutomaticallyUpdate -bool YES` y `SULastCheckTime` antiguo, lanzarla con `TERMINALY_STATE_DIR` temporal y mirar `~/Library/Caches/<id>/org.sparkle-project.Sparkle/`. Borrar después ese dominio de defaults y la caché.
- Publicar una release es visible para todos: pregunta antes.

## Trampas conocidas

- **SwiftTerm**: la salida del proceso NO pasa por `dataReceived` (va por un adapter interno); usa `setProcessOutputHandler`. No hay `cols`/`rows` públicos: el tamaño se guarda desde `sizeChanged` (`gridSize`). `becomeFirstResponder` no es `open`; los métodos de delegado chocan con métodos públicos de `TerminalView`, así que el delegado es un objeto aparte (`TerminalBridge`). Leer la pantalla: `selectAll()` + `getSelection()`.
- **Rendimiento**: perfilado el 2026-11-11 (`sample <pid>`), el daemon gasta ~0,1 % de CPU y nuestro código en la app <1 %; casi todo el coste es el pintado de SwiftTerm con CoreGraphics en el hilo principal (reconstruye `NSAttributedString` por fila en cada repintado; un agente animando su línea de estado ocupa ~20–28 % del hilo principal). Ajustes → Terminal → «Dibujar los terminales con la GPU» (`terminalGPU`, activado por defecto desde el 2026-11-12, tras comprobarlo el autor en pantalla) llama a `setUseMetal` de SwiftTerm: pinta en un hilo aparte con atlas de glifos (TUI tipo agente: 9,4 % → 4,9 % de CPU de la app, hilo principal ~2 %; con inundación de salida el total no baja, pero sale del hilo principal). Metal necesita ventana (`AgentTerminalView.viewDidMoveToWindow`) y no sale en el modo snapshot (`cacheDisplay` no captura la capa Metal), por eso ahí se fuerza CoreGraphics. `TERMINALY_GPU=0|1` lo fuerza en pruebas. Una ventana tapada no se pinta: para medir hay que traerla al frente.
- **TerminalContainer**: SwiftUI reutiliza el `NSViewRepresentable` del panel al cambiar de sesión. El contenedor debe quedarse con un único subview (el terminal actual) y lleva `.id(session.id)`; si no, los terminales se apilan y al volver a una sesión se ve otra (paso 6 del self-test).
- **Ancho de la barra lateral**: cualquier hijo más ancho que la columna (el pie con muchos workspaces, títulos largos) ensancha el carrusel y saca de la vista el borde derecho ("+" de proyecto, Ajustes). Páginas y pie van con `.frame(width: geo.size.width)`. Prueba siempre con una copia del `state.json` real (muchos workspaces y títulos largos), no solo con datos cortos.
- **Sidebar List**: los SF Symbols coloreados en cabeceras de sección salen blancos; usa formas rellenas (badge con letra). La selección nativa sale negra con la ventana inactiva: la selección se dibuja a mano en `selectableRow`.
- **Botones que solo aparecen con hover**: si el botón que abre un popover se quita al perder el hover, SwiftUI cierra el popover en cuanto el ratón entra en él. Pásale `isOpen:` a `PopoverMenuButton` y muéstralo con `hovering || menuOpen`.
- **Animaciones infinitas**: nada de `.repeatForever()` en SwiftUI. Cada vez que se vuelve a disparar, SwiftUI combina otra animación infinita que nunca termina (`DefaultCombiningAnimation`). Tras horas de cambios de estado, el hilo principal acaba al 100 %. Los pulsos van con `CABasicAnimation` sobre un layer (`PulsingDot` en `SidebarView.swift`).
- **Rutas de socket** limitadas a 104 bytes: si el `stateDir` es largo se usa `/tmp/tly-<uid>-<hash>.sock`.
- **Nada bloquea la cola del daemon**: es una sola cola serie para todas las sesiones. Escribir al PTY con bucle `write`+`usleep` colgó el daemon entero cuando una sesión pausada (o colgada) dejó de leer: además se interbloquea con su propia salida, que el daemon ya no lee. La entrada va a `pendingInput` + `DispatchSourceWrite` y se descarta en pausa.
- `SyncConnection.request` guarda los eventos que llegan antes de la respuesta en otra cola; no los vuelvas a meter en la de lectura (bucle infinito).
- Instalación limpia sin `state.json`: el store crea el workspace "Personal" en `init`. Cualquier dato nuevo debe tener un valor por defecto válido en ese caso.
- Al reinstalar o actualizar la app, las sesiones siguen vivas en el daemon; la app nueva se vuelve a conectar. No mates `tly daemon` sin preguntar: corta los agentes del usuario.

## Convenciones

- Código, comentarios y commits en inglés; conversación con el usuario en español.
- Comentarios solo para el porqué, no el qué. Mismo estilo que el código existente.
- Commits pequeños por funcionalidad; push a `main` cuando el usuario lo pida o lo haya autorizado para el flujo en curso.

# Terminaly

App nativa de macOS para lanzar y vigilar sesiones de agentes CLI (Claude Code, Codex, shells), inspirada en Unpeel. Repo público: https://github.com/drarekx/terminaly. Plan de trabajo en `ROADMAP.md`: márcalo al completar elementos. Mantén este archivo al día cuando cambie la arquitectura, el flujo de release o aparezca una trampa nueva.

## Estructura

SwiftPM, macOS 14+, Swift 6 toolchain en modo de lenguaje 5 (`swiftLanguageMode(.v5)` en todos los targets).

| Target | Qué es |
|---|---|
| `Terminaly` | App SwiftUI. Renderiza terminales (SwiftTerm `TerminalView`), no es dueña de ningún proceso. |
| `tly` | Daemon de sesiones (`tly daemon`, se arranca solo) + CLI (`tly ls/new/send/logs/attach/wait/kill/rm/shutdown`). |
| `TerminalyKit` | Protocolo compartido: framing, `Message`, sockets Unix, lanzador del daemon, rutas. |

Dependencias: SwiftTerm (terminal), Sparkle 2 (auto-update). Nada más.

### Daemon `tly` (`Sources/tly`)
- Un solo proceso para todas las sesiones. PTYs con `forkpty` (`Pty.swift`); todo en una cola serie con DispatchSources (kqueue): cero CPU en reposo, sin polling salvo un timer de 30 s.
- Ring buffer de 2 MB por sesión para replay al hacer `attach`.
- Servidor HTTP de hooks en `127.0.0.1:<puerto aleatorio>` con token por ejecución (`HookServer.swift`). Las sesiones reciben `TERMINALY_SESSION_ID`, `TERMINALY_HOOK_PORT`, `TERMINALY_HOOK_TOKEN`.
- El estado (`starting/working/idle/needsInput/exited`) se calcula en el daemon (`HostedSession`): por hooks si la sesión los envía, si no por actividad de salida (working mientras sale texto, idle tras 2 s). Solo notifica sesiones con hooks.
- Se cierra solo tras 60 s sin sesiones vivas ni clientes.
- Socket: `~/Library/Application Support/Terminaly/tly.sock`, permisos 0600, solo acepta peers con el mismo UID.

### Protocolo (`TerminalyKit/Protocol.swift`)
Frames `[UInt32 BE longitud][UInt8 tipo][payload]`. Tipos: `json` (un `Message` plano con `type`), `output`/`input` (16 bytes de UUID + bytes crudos). Peticiones con `reqID`, eventos sin él (`sessions`, `status`, `removed`). Si cambias el protocolo, sube `protocolVersion`: tras una actualización puede quedar corriendo un daemon antiguo.

### App (`Sources/Terminaly`)
- `Model/AppStore.swift`: estado único `@Observable` (workspaces, proyectos, sesiones, presets, layout de paneles). Persistencia en `state.json` (escritura con debounce de 400 ms). Los campos nuevos de `PersistedState` deben ser opcionales o con `decodeIfPresent`: hay usuarios con archivos antiguos (ver migración a workspace "Personal" en `load()`).
- `Terminal/DaemonClient.swift` + `TerminalRegistry.swift`: conexión asíncrona al daemon en main queue; un `AgentTerminalView` por sesión, reutilizado y re-parentado (`TerminalContainer`).
- Workspaces: cada uno tiene nombre, icono, color y su propio `PaneNode` (árbol de splits). El layout vivo está en `store.layout` y se vuelca al workspace con `commitLayout()` al cambiar o guardar.
- Hooks de Claude Code: `Hooks/HookInstaller.swift` escribe en `~/.claude/settings.json` (con backup `.terminaly-backup`); las entradas se reconocen por contener `TERMINALY_SESSION_ID`.

## Diseño ("Graphite")

Canvas: https://claude.ai/artifact/NXCTs7pMK3XnPDpKTfmoPY. Tokens en `UI/Theme.swift`; no inventes colores sueltos en las vistas.
- App siempre oscura (`preferredColorScheme(.dark)`). Fondo `0x0B0C0E`, tarjeta de terminal `0x0F1013`, texto `0xECECF1`.
- Barra lateral: mezcla sólida del 20 % del color del workspace sobre grafito (`Theme.sidebar`), sin degradados.
- El color del workspace (`store.accent`) marca foco, selección y botón principal. Los colores de estado (azul/verde/ámbar/gris en `SessionStatus.dot/text/tile`) son solo para agentes.
- Tipografía: solo `Theme.Font` (12 pt mínimo para texto legible); texto secundario `Theme.secondaryText`/`tertiaryText`.
- Botones: `PrimaryButtonStyle` (una acción principal por zona), `SecondaryButtonStyle`, `IconButtonStyle` (+ `.help`/`.accessibilityLabel`). El color del workspace llega por `@Environment(\.workspaceAccent)`: `Color.accentColor` ignora `.tint`. Los popovers viven en otra ventana; `PopoverMenuButton` les pasa el acento.
- Menús frecuentes = `PopoverMenu` + `MenuRow`/`MenuSectionLabel`/`ColorSwatchRow`/`SymbolGrid`; los menús contextuales (clic derecho) siguen nativos.
- Temas de terminal en `Terminal/TerminalTheme.swift` (`installColors` + fondo/texto/cursor); el fondo de la tarjeta del panel sigue al tema.

## Idioma

- Inglés es el idioma de desarrollo (las claves son el texto en inglés). Traducción en `Resources/es.lproj/Localizable.strings`; `bundle.sh` copia `Resources/*.lproj` al `.app`. Hace falta `en.lproj` aunque esté vacío, o un sistema en inglés recibe español.
- Todo texto visible debe ser `LocalizedStringKey` (literal en `Text`/`Button`/`.help`, `MenuRow(title:)`) o `String(localized:)`. Un ternario de literales o un `String` concatenado NO se traduce: usa `LocalizedStringKey(...)` explícito o `if/else`.
- Al añadir textos, extrae las claves y traduce las que falten: `swift build --product Terminaly -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>` genera `.stringsdata` (JSON) por archivo.
- Selector en Ajustes → General (`AppLanguage`: escribe `AppleLanguages` del dominio de la app y relanza). Probar sin tocar ajustes: pasar `-AppleLanguages "(es)"` al ejecutable. El sistema del autor está en catalán con español detrás, así que "Sistema" muestra español.

## Comandos

```sh
swift build                                   # debug
./scripts/bundle.sh [release|debug]           # → build/Terminaly.app (incluye tly y Sparkle.framework)
TERMINALY_STATE_DIR=$(mktemp -d) .build/debug/Terminaly --selftest   # test end-to-end, debe imprimir SELFTEST PASS
TERMINALY_STATE_DIR=<dir con state.json> TERMINALY_SNAPSHOT_DIR=<out> build/Terminaly.app/Contents/MacOS/Terminaly
                                              # renderiza la ventana a PNG (un archivo por workspace, máx 3) + menus.png
                                              # extra: TERMINALY_SNAPSHOT_SHELL='cmd' abre una shell real; TERMINALY_SETTINGS_TAB=terminal|general captura Ajustes
./scripts/release.sh 0.3.0 "notas"            # publica release + appcast (ver abajo)
```

- **Verifica siempre con `--selftest`** antes de commitear cambios en store, daemon o protocolo. Cubre: workspaces (y migración si `SELFTEST_EXPECT_LEGACY_PROJECTS=N`), hooks → needsInput, heurística working → idle, y reinicio simulado de la app con replay.
- El texto del terminal no siempre sale en la captura (el buffer sí lo tiene: compruébalo con `screenText()`); el resto de la UI sí es fiel.
- Para cambios visuales usa el modo snapshot: no hay permiso de grabación de pantalla, pero la app se pinta a sí misma (`cacheDisplay`). Siembra un `state.json` de prueba en un directorio temporal; nunca uses el estado real del usuario.
- Usa siempre `TERMINALY_STATE_DIR` en pruebas: si no, tocarías `~/Library/Application Support/Terminaly` (datos reales y el daemon real).

## Release y auto-update

- Sparkle lee `https://github.com/drarekx/terminaly/releases/latest/download/appcast.xml`. `release.sh` compila, firma el zip con la clave EdDSA del llavero (`sign_update`), genera el appcast, crea el tag, hace push y publica la release con `gh` (zip versionado, `Terminaly.zip` para el instalador y `appcast.xml`).
- `CFBundleVersion` = número de commits (`git rev-list --count HEAD`); `CFBundleShortVersionString` = archivo `VERSION`.
- Firma de código ad-hoc (no hay Developer ID). Sparkle acepta el cambio de firma porque la clave EdDSA es la misma; **no cambies `SUPublicEDKey`** o las copias instaladas dejarán de actualizarse. La clave privada solo está en el llavero de macOS del autor.
- Instalador: `curl -fsSL https://raw.githubusercontent.com/drarekx/terminaly/main/install.sh | bash` (instala en /Applications, enlaza `tly`, quita la cuarentena). Variables de prueba: `TERMINALY_ZIP_URL`, `TERMINALY_INSTALL_DIR`, `TERMINALY_BIN_DIR`, `TERMINALY_NO_OPEN`.
- Publicar una release es visible para todos: pregunta antes.

## Trampas conocidas

- **SwiftTerm**: la salida del proceso NO pasa por `dataReceived` (va por un adapter interno); usa `setProcessOutputHandler`. No hay `cols`/`rows` públicos: el tamaño se guarda desde `sizeChanged` (`gridSize`). `becomeFirstResponder` no es `open`; los métodos de delegado chocan con métodos públicos de `TerminalView`, así que el delegado es un objeto aparte (`TerminalBridge`). Leer la pantalla: `selectAll()` + `getSelection()`.
- **Sidebar List**: los SF Symbols coloreados en cabeceras de sección salen blancos; usa formas rellenas (badge con letra). La selección nativa sale negra con la ventana inactiva: la selección se dibuja a mano en `selectableRow`.
- **Rutas de socket** limitadas a 104 bytes: si el `stateDir` es largo se usa `/tmp/tly-<uid>-<hash>.sock`.
- `SyncConnection.request` guarda los eventos que llegan antes de la respuesta en otra cola; no los vuelvas a meter en la de lectura (bucle infinito).
- Instalación limpia sin `state.json`: el store crea el workspace "Personal" en `init`. Cualquier dato nuevo debe tener un valor por defecto válido en ese caso.
- Al reinstalar o actualizar la app, las sesiones siguen vivas en el daemon; la app nueva se vuelve a conectar. No mates `tly daemon` sin preguntar: corta los agentes del usuario.

## Convenciones

- Código, comentarios y commits en inglés; conversación con el usuario en español.
- Comentarios solo para el porqué, no el qué. Mismo estilo que el código existente.
- Commits pequeños por funcionalidad; push a `main` cuando el usuario lo pida o lo haya autorizado para el flujo en curso.

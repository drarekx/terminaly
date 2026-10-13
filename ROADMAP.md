# Roadmap

Orden aproximado por versiones. Esfuerzo: **S** (horas), **M** (1–2 días), **L** (varios días). Lo marcado con ★ lo ha pedido el usuario.

## v0.3 — Pulido visual ✅

Hecho: menús en popover, botones legibles, escala tipográfica, interfaz en español (con selector de idioma), 6 temas de terminal y elección de fuente, zoom de panel (⌘↩) y arrastrar sesiones a paneles.

| | Mejora | Qué y por qué | Esfuerzo |
|---|---|---|---|
| ★ | Menús con más espacio | Los menús nativos de macOS no permiten cambiar el alto de fila. Los menús que más se usan (nueva sesión, workspace, proyecto, sesión) pasan a popovers propios: filas de 32–36 px, icono, texto a 13 pt y atajo alineado a la derecha. Los menús contextuales secundarios se quedan nativos. | M |
| ★ | Botones más legibles | Mínimo 13 pt y contraste 4,5:1 en todo texto de botón; alto mínimo de 32 px (28 px en la barra lateral); estados hover/pressed visibles. Los botones de solo icono de la barra superior muestran la etiqueta al pasar el ratón, y la acción principal ("New Session") lleva texto. | S |
| | Escala tipográfica | Fijar 4 tamaños (11/12/13/17) y 3 pesos en `Theme`, y que ninguna vista use tamaños sueltos. Hoy hay demasiados 11 pt en gris claro. | S |
| | Interfaz en español | String Catalog con es/en; el idioma sigue al del sistema. | S |
| | Temas de terminal | Esquemas de color (Graphite, Solarized, Dracula…), elegir fuente, interlineado y opacidad. | M |
| | Zoom de panel | ⌘↩ maximiza el panel con foco y vuelve al layout al repetir. | S |
| | Arrastrar sesiones a paneles | Soltar una sesión de la barra lateral en un panel o en su borde (crea un split en ese lado). | M |

## v0.4 — Agentes

| | Funcionalidad | Qué y por qué | Esfuerzo |
|---|---|---|---|
| | Aprobar desde la notificación | Botones «Permitir» / «Denegar» en la notificación y en la cabecera del panel cuando Claude pide permiso, sin tener que ir al terminal. | M |
| | Reanudar tras reiniciar el Mac | El hook guarda el `session_id` de Claude; «Reanudar» relanza con `claude --resume <id>` en la misma carpeta. Hoy, tras un reinicio, solo se puede empezar de cero. | M |
| | Más agentes con estado | Hook `notify` de Codex y notificaciones OSC 9/777 de cualquier programa: estado y avisos sin depender de la heurística de salida. | M |
| | Worktrees por sesión | «Nueva sesión en worktree»: crea la rama y el worktree, y muestra la rama en la fila. Varios agentes en el mismo repo sin pisarse. | M |
| | Buscar en el historial | ⌘F en el panel (la barra de búsqueda de SwiftTerm) y búsqueda global sobre los logs del daemon desde la paleta. | M |
| | Plantillas de proyecto | Un proyecto puede definir sus sesiones de arranque (p. ej. Claude + `npm run dev` + shell) y lanzarlas con un clic. | S |

## v0.5 — Sesiones en la red local ★

Ver y controlar las sesiones de otro Mac de la misma red como si fueran locales.

**Cómo funcionaría**
- **Activación manual en cada Mac, desactivada por defecto**: Ajustes → «Compartir este Mac». El daemon `tly` abre entonces un puerto TCP; si está desactivado, no escucha en red.
- **Descubrimiento con Bonjour** (`_terminaly._tcp`): los Macs con Terminaly aparecen solos en «Cerca de ti», sin escribir IPs.
- **Emparejado con código**: el Mac anfitrión muestra un código de 6 dígitos y el otro lo introduce. Se intercambian certificados y quedan anclados: en adelante, conexión TLS mutua sin código.
- **Permisos por dispositivo**: solo ver, o ver y controlar (escribir y aprobar). Se revocan desde Ajustes.
- **En la barra lateral**: cada Mac remoto es una sección con su nombre y un indicador de conexión; sus sesiones muestran estado, notificaciones y salida en directo usando el mismo protocolo de frames que ya existe.
- **Coste**: el daemon sigue siendo un único proceso; solo se añade un listener TCP mientras está activo.

**Por fases**
1. Descubrimiento, emparejado y lista de sesiones remotas en solo lectura. (L)
2. Ver la salida en directo y adjuntarse (`tly attach host:id` también desde la CLI). (M)
3. Control: escribir, aprobar permisos y lanzar sesiones nuevas en el remoto. (M)

**Más adelante**: acceso fuera de la red local (relay o Tailscale) y una app para iPhone que reciba los avisos y apruebe permisos.

## v0.6 — Productividad

| | Funcionalidad | Qué y por qué | Esfuerzo |
|---|---|---|---|
| | Icono en la barra de menús | Sesiones que piden respuesta y aprobación rápida sin abrir la ventana. | M |
| | Enviar a varias sesiones | Escribir un prompt una vez y mandarlo a las sesiones seleccionadas. | S |
| | Grupos y filtros | Filtrar la barra lateral por estado (pide respuesta, trabajando) y buscar sesiones por nombre. | S |
| | Coste y tokens | Mostrar el coste y los tokens por sesión cuando el agente los reporte en sus hooks. | M |

## Infraestructura (continua)

- **Firma Developer ID y notarización**: elimina el aviso de Gatekeeper en la primera instalación. Necesita una cuenta de Apple Developer.
- **CI en GitHub Actions**: compilar y pasar el self-test en cada push; publicar la release desde CI.
- **Tests unitarios** del protocolo, de `PaneNode` y de la migración de `state.json`, además del self-test.
- **Versionado del protocolo** en el `hello`: si la app y el daemon no coinciden tras una actualización, avisar y ofrecer reiniciar el daemon cuando no tenga sesiones.
- **Actualizaciones delta** de Sparkle para descargas más pequeñas.

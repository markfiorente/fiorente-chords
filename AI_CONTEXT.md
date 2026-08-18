# Fiorente Chords — Contexto para IA

Este documento resume el proyecto para que cualquier asistente de IA pueda retomarlo sin
necesitar el historial de conversación previo. Está escrito para ser leído por una IA, no
por el usuario final.

## Qué es esto

**Fiorente Chords** es una app web de cifrados musicales para bandas/iglesias de
adoración (contexto hispanohablante, Colombia). Permite transportar cifrados en tiempo
real, tiene un "Modo En Vivo" pensado para tocar en el escenario, y cada banda/iglesia
tiene su propio equipo privado con su propio repertorio.

Es la evolución multi-equipo de una herramienta personal anterior, **Mark Chords**
(repo separado `mark-chords`, sigue en producción sin cambios, es la app personal de
"Mark", el dueño del proyecto — **nunca se debe tocar ese repo/carpeta** al trabajar en
este). `index.html` de este repo partió como una copia literal del de `mark-chords` y
evolucionó por separado.

**El usuario (dueño del proyecto) no es programador** — es un músico/pianista que dirige
todo el desarrollo por instrucciones en lenguaje natural, en español. No asumas
conocimiento técnico; explica en términos simples cuando converses con él, y prueba tú
mismo los cambios (no le pidas que verifique código).

## Arquitectura

- **Un solo archivo**: `index.html` — sin build step, sin framework, sin npm/bundler.
  HTML + Tailwind (CDN) + Font Awesome (CDN) + JS vanilla, todo en una sola etiqueta
  `<script>` al final del archivo.
- **Dependencias por CDN** (sin instalar nada): Tailwind, Font Awesome, Google Fonts,
  `xlsx.js` (import de Excel), `@supabase/supabase-js@2` (cliente de Supabase).
- **Backend: Supabase** (Postgres + Auth + Row Level Security + Storage). No hay
  servidor propio ni funciones serverless — todo el CRUD es directo desde el navegador
  al cliente de Supabase, protegido por RLS.
- **Despliegue**: GitHub Pages, estático, sin CI. Repo:
  `https://github.com/markfiorente/fiorente-chords` → publicado en
  `https://markfiorente.github.io/fiorente-chords/`. Cualquier `git push` a `main` se
  refleja ahí solo (GitHub Pages ya está configurado para servir desde `main`/root).

### Credenciales (ya están hardcodeadas en `index.html`, son seguras de exponer)

```js
const SUPABASE_URL = 'https://fubiopqgycwlyngvcntl.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'; // rol "anon", pública
```

Es la llave pública (`anon`), diseñada para vivir en el cliente — la seguridad real la
da RLS en la base de datos, no el secreto de esta llave. **Nunca** se debe usar la
`service_role` key en este archivo (esa sí es secreta; solo se usaría en un script
de migración corrido localmente, fuera de la app).

## Modelo de datos (Supabase / Postgres)

Migraciones en `supabase/migrations/`, se corren a mano en el SQL Editor de Supabase
(no hay CLI/CI conectado — cuando agregues una migración nueva, avísale al usuario
que tiene que copiarla y correrla él mismo ahí, con instrucciones paso a paso).

- **`0001_init.sql`**: esquema base.
  - `teams(id, name, slug, created_by, plan, song_limit)`
  - `memberships(team_id, user_id, role admin|member)` — cualquier miembro edita
    canciones/setlist; `admin` solo controla invitar/remover miembros.
  - `songs(id uuid, team_id, import_key, title, artist, key, original_key, bpm,
    youtube, mp3, sheet_music, sequence text[], annotations, chords, favorite, ...)`
    — una fila por canción. `import_key` es el slug estable título+artista, usado por
    el import de Excel/Sheets para actualizar en vez de duplicar (el `id` real es un
    uuid que asigna Postgres al insertar).
  - `setlist_items(team_id, song_id, position)` — el "setlist de hoy".
  - `invite_tokens(team_id, token, created_by, expires_at, max_uses, uses)`.
  - Función `is_team_member(team_id)` / `is_team_admin(team_id)` (security definer) —
    la base de TODAS las políticas RLS: "puedes leer/escribir esto si eres miembro de
    ese equipo". Ningún equipo puede ver el repertorio de otro, ni con un bug en el
    cliente.
  - RPCs (security definer, para evitar problemas de "huevo y gallina" con RLS):
    `create_team_with_owner(team_name)`, `create_invite(team_id, max_uses)`,
    `redeem_invite(token)`.
- **`0002_tags_recent_sheet_images.sql`**: agrega a `songs` las columnas
  `tags text[]`, `last_used_at timestamptz`, `sheet_image_path text`; crea el bucket
  de Storage `sheet-images` (privado) con políticas RLS que leen el `team_id` del
  primer segmento de la ruta del archivo (`{team_id}/{song_id}/{archivo}`), reusando
  `is_team_member`.
  - **Gotcha ya resuelto**: NO se puede correr `ALTER TABLE storage.objects ENABLE ROW
    LEVEL SECURITY` desde el SQL Editor normal de Supabase (da `must be owner of table
    objects` — esa tabla la administra Supabase internamente). No hace falta: RLS ya
    viene activada por defecto ahí. Si necesitas otra migración sobre
    `storage.objects`, solo agrega políticas (`create policy`), no toques la tabla.

## Autenticación

- **Magic link** (correo sin contraseña), vía `sb.auth.signInWithOtp({ email, options:
  { emailRedirectTo: location.origin + location.pathname } })`. Pensado para
  voluntarios de iglesia no técnicos.
- Primer ingreso sin equipo → pantalla forzada "Crea tu equipo" (`renderAuthGate` en
  `index.html`, función `bootstrapSession`).
- Invitaciones: link con token (`?invite=TOKEN` en la URL) — al cargar, si hay token en
  la URL y el usuario está logueado, se canjea automático vía `redeem_invite`.
- **Importante si cambias el dominio de despliegue**: la URL de redirect del magic link
  tiene que estar autorizada en Supabase → Authentication → URL Configuration →
  Redirect URLs. Si algún día se agrega Capacitor (apps nativas), este flujo entero
  necesita Universal Links/App Links — ver sección "Ideas futuras" más abajo.

## Estructura del código dentro de `index.html`

No hay archivos separados — busca por estos comentarios de sección (`/* ===... */`)
dentro del único `<script>`:

- `CONSTANTES DE TRANSPOSICIÓN` — arrays cromáticos, `transposeNote`/`transposeChord`.
  **No tocar la lógica de transposición sin entender bien las notas enarmónicas
  (sostenidos vs bemoles)** — ya tiene varios ajustes finos de bugs pasados.
- Render de cifrado: `classifyLine`, `isChordLine`, `renderChordChart`,
  `extractSectionLabels` — reconoce líneas de acordes vs. letra vs. encabezados de
  sección (`[CORO]`, etc.) y símbolos musicales Unicode.
- `CAPA DE DATOS` / sección Supabase — `coerceSong` (sanitiza cualquier dato entrante,
  de Supabase o de un backup .json importado), `rowToSongObj`/`songPatchToRow`
  (mapeo camelCase↔snake_case), `fetchTeamSongs`, `addSong`/`updateSong`/`deleteSong`
  (escrituras optimistas por fila, no por archivo completo — este es el patrón a
  seguir para cualquier CRUD nuevo).
- `METRÓNOMO` — Web Audio API con lookahead scheduler (no usar `setInterval` puro para
  timing de audio, se desfasa).
- `ESTADO GLOBAL + NAVEGACIÓN` — objeto `state` (fuente de verdad del cliente),
  `getVisibleLibraryList` (búsqueda + filtros + orden de la biblioteca).
- `MAIN / DETAIL PANE` — `renderMain()`, vista de detalle de una canción.
- `STAGE MODE` — Modo En Vivo: `enterStageMode`, `stageGoTo` (navegación
  siguiente/anterior con wrap-around, respeta el setlist del día si existe),
  auto-scroll, salto a sección tocando el encabezado.
- `PARTITURA EN IMAGEN/PDF` — subida/lectura desde el bucket de Storage, con URLs
  firmadas de corta duración (no público).
- `IMPORTACIÓN EXCEL / CSV` — detecta encabezados por alias en español/inglés
  (`FIELD_ALIASES`), tolerante a variaciones de nombre de columna.
- `AUTENTICACIÓN Y EQUIPOS` — todo el flujo de login/equipo/invitación.
- `CARGA INICIAL` / `INIT` al final — arranque de la app.

### Patrón de escritura a Supabase (seguir este patrón para features nuevas)

Escrituras **por fila individual**, optimistas (se aplica al estado local y se
re-renderiza YA, la llamada a Supabase va después; si falla, se revierte y se avisa
con un toast). Esto es deliberado — reemplazó un modelo viejo (heredado de
`mark-chords`) que subía el repertorio completo como un solo archivo JSON a GitHub, lo
cual causaba que dos ediciones simultáneas se pisaran. **No reintroducir ese patrón.**

## Funcionalidades ya construidas

- Transposición cromática en vivo (sostenidos/bemoles, tonos menores, calidad de
  acorde).
- Modo En Vivo: pantalla completa, fuente grande, auto-scroll configurable,
  navegación siguiente/anterior (respeta el setlist activo), salto a sección.
- Setlist "de hoy" (reemplazo completo de filas al guardar, no fraccionado).
- Reproductor MP3 (incluye links de Google Drive) y referencia de YouTube.
- Import de Excel/Google Sheets (detección de encabezados, fusiona o reemplaza).
- Backup/restauración manual en `.json`.
- Multi-equipo con RLS real, invitaciones por link.
- Metrónomo (usa el BPM guardado por canción).
- Imprimir/exportar a PDF (usa el diálogo nativo del navegador, sin librería).
- Etiquetas por canción + filtro; "usadas recientemente" (se marca al entrar a Modo En
  Vivo, no al solo abrir la canción).
- Subir foto/PDF de partitura por canción (privado por equipo, visible también dentro
  de Modo En Vivo en una capa superpuesta) — **versión simple a propósito**: no hay
  conversión a texto ni reconocimiento óptico de partitura, decisión explícita del
  usuario.

## Decisiones de producto/legales importantes (no las reabras sin contexto)

- **Modelo de contenido de usuario, no distribución de contenido con licencia**: el
  usuario fue explícito en que la app no provee cifrados — cada equipo sube y es
  dueño de su propio contenido, como GitHub/Dropbox. Esto es lo que hace legalmente
  razonable operar esto como servicio multi-iglesia sin licencias tipo CCLI. No
  agregues un catálogo de canciones compartido entre equipos ni nada que empuje hacia
  "plataforma que distribuye cifrados".
- Pendiente antes de un lanzamiento más público: Términos de Servicio, Política de
  Privacidad, registro de agente DMCA (~$6 USD, trámite en EE.UU.).
- Monetización planeada (no implementada): freemium por suscripción, sin publicidad.

## Ideas futuras ya evaluadas, no construidas todavía

Priorizadas con el usuario, en dos tandas:

**Ya construidas (Fase 1 de mejoras)**: metrónomo, imprimir/PDF, etiquetas +
recientes, partitura en imagen — ver arriba.

**Pendientes (Fase 2/3, en orden de prioridad acordado)**:
1. Sugerencia de capo (heurística nueva sobre el motor de transposición existente).
2. Transposición para instrumentos Bb/Eb (viento) — barata técnicamente, reutiliza
   `transposeChord`, pero solo vale la pena si el equipo tiene esos instrumentos.
3. Funcionar sin internet (PWA: `manifest.json`, `sw.js`, cachear el cascarón de la
   app SIN cachear las llamadas a Supabase). Alto valor (perder el cifrado a mitad de
   una canción es el peor escenario) pero requiere cuidado para no mostrar datos
   viejos.
4. Vista en números Nashville — baja prioridad, es una convención poco común entre
   músicos de iglesia en Colombia.

**App nativa iOS/Android** (analizado a fondo, no aprobado para construir todavía):
recomendación es empezar por PWA (gratis, sin revisión de terceros) antes que
Capacitor (requiere Mac, $99/año Apple Developer, $25 único Google Play, y cambiar el
login por magic link a Universal Links o a un código de 6 dígitos con `verifyOtp`
porque un link `https://` plano no abre una app envuelta directamente). Descartada
reescritura nativa por ahora.

## Cómo probar cambios localmente

No hay dev server configurado por defecto (es HTML estático). Patrón usado en este
proyecto para probar antes de desplegar:
1. Servir la carpeta con un server HTTP simple (Node, ver
   `.claude/launch.json` del repo hermano `Worship` si existe una config previa) —
   **no usar `file://` directo**, el cliente de Supabase y varias APIs del navegador
   no funcionan bien sin origen http(s).
2. Para probar sin depender de una sesión real: se puede inyectar estado falso desde
   la consola del navegador (`currentTeam`, `currentUser`, `state.songs`, luego llamar
   `hideAuthGate()` y las funciones `render*` a mano) — así se prueba la UI sin tocar
   datos reales de Supabase. Los errores de red esperados (ej. `createSignedUrl`
   contra un bucket/ruta falsa) deben fallar con gracia (mensaje de error, no crash) —
   si no, es un bug.
3. Antes de dar por buena una migración SQL nueva, verificar contra el proyecto real
   con la llave `anon` (sin sesión) que las columnas/bucket existan y no den error
   (aunque los datos vuelvan vacíos por RLS, un error de "columna no existe" sí se
   vería).
4. Deploy: commit + push a `main` del repo `fiorente-chords` → se refleja solo en
   GitHub Pages en un par de minutos.

## Otros archivos del repo

- `README.md` — descripción corta orientada al usuario/lector humano del repo.
- `supabase/migrations/*.sql` — migraciones, se corren a mano (ver arriba).
- `.claude/launch.json` — config local de un servidor de preview para pruebas
  (gitignored, no se sube).

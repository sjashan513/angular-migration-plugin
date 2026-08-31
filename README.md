# angular-migration — Plugin para GitHub Copilot (v3)

Plugin de siete agentes con tres entradas independientes: migración Angular major por major, diagnóstico mecánico del código y documentación visual entre despliegues.

## Agentes

| Agente       | Rol                                                                            | Modelo          |
| ------------ | ------------------------------------------------------------------------------ | --------------- |
| **Hermes**   | Orquestador. Gates, rama, snapshot de versiones, fleet y verificación.         | GPT-5.6 Luna    |
| **Cronos**   | Documenta el porqué del salto a partir del snapshot.                           | GPT-5.6 Luna    |
| **Prometeo** | Construye el plan ejecutable a partir del snapshot.                            | Grok 4.6 \*     |
| **Hefesto**  | Ejecuta el plan: `ng update` vía script, cambios manuales, build, warnings.    | Claude Sonnet 5 |
| **Clío**     | Consolida la documentación en `docs/migration/` (changelog, diff, índice, KB). | GPT-5.6 Luna    |
| **Asclepio** | Escanea `src/` y aplica solo fixes mecánicos verificables.                     | Claude Sonnet 5 |
| **Helios**   | Documenta rutas y compara dos URLs con Playwright.                             | GPT-5.6 Luna    |

\* Requiere activar la policy de Grok 4.6 en Copilot Business/Enterprise. Fallback: edita el frontmatter de `Prometeo.agent.md` y cambia el modelo a `claude-sonnet-5 (copilot)`.

Por cada salto (p. ej. v8→v9), Hermes mantiene la pipeline original de cinco agentes. Asclepio y Helios son autónomos y nunca forman parte de su fleet.

## Prerequisitos

- GitHub Copilot Business o Enterprise con `/fleet` habilitado
- `chat.subagents.allowInvocationsFromSubagents: true` en VS Code
- PowerShell 5.1+ (Windows) — el script vive en el plugin, no necesitas copiarlo
- Node.js y npm instalados; `fnm` o `nvm` para gestionar versiones de Node
- `fnm` o `nvm` disponibles para que el runtime aislado pueda instalar Node 20+
  si falta; el plugin instala Playwright, Chromium y el comparador PNG en
  `%LOCALAPPDATA%\angular-migration-plugin\playwright-runtime` durante el primer
  salto, sin modificar `package.json` ni `node_modules` de la app

## Instalación

```bash
# Registrar marketplace (solo la primera vez)
copilot plugin marketplace add sjashan513/angular-migration-plugin

# Instalar el plugin
copilot plugin install angular-migration@sjashan513-plugins
```

## Migrar Angular

Abre Copilot en la raíz del repo Angular y escribe:

```
/update-angular 17
```

O directamente con el agente:

```
@Hermes 17
```

Hermes detecta la versión actual, calcula los saltos pendientes (p. ej. 7→8→…→17) y ejecuta la pipeline completa. Solo te parará si:

1. El working tree está sucio → haz commit o stash y confirma.
2. Node no se pudo activar solo (sin `fnm`/`nvm` o fallo de instalación) → te da el comando exacto a ejecutar.
3. No se puede instalar Node 20+ para preparar Playwright → te da el error para resolverlo.
4. Alguna dependencia no tiene metadata npm → te muestra los paquetes afectados y te pregunta si quieres continuar con metadata parcial.
5. Un salto falla 3 veces o Cronos no deposita su documento tras un reintento → te expone el problema para que decidas.

> **Gestión de Node automática:** cada salto exige un major de Node (p. ej. 10 para Angular 8, 18 para Angular 17). El plugin lo detecta con `fnm` o `nvm`, lo instala si falta y lo activa sin que hagas nada.

Si npm no puede consultar alguna dependencia, `write-snapshot` conserva el snapshot y lista los paquetes afectados. Hermes te pregunta si quieres continuar con metadata parcial; si aceptas, los agentes trabajan solo con los datos disponibles y marcan lo no verificado.

Cada salto genera `changes-v{N}.json`: una transformación aplicada muchas veces aparece una sola vez con todas sus ubicaciones en `occurrences[]`. Hermes no acepta un salto si algún fichero del diff queda sin explicar.

### Progreso en terminal

Durante la migración, Hermes actualiza una barra ASCII por cada hito del salto y el script la imprime por `stderr`, sin romper su contrato JSON. El último estado queda en `.angular-migration/progress.json`, con `current`, `total`, `label` y `status` (`pending`, `running`, `completed` o `failed`).

## Diagnosticar el código

```text
@Asclepio
@Asclepio scan-only
```

Asclepio lee las versiones y herramientas del proyecto, escanea `src/` completo y ejecuta los checks ya configurados. En modo normal aplica únicamente reglas `safe-fix`; nunca cambia dependencias, lógica, ramas ni commits. Genera artefactos bajo `.angular-migration/diagnostics/` y un resumen en `docs/diagnostics/`.

## Comparar vistas

```text
@Helios
```

Helios pide primero la URL que debe documentar. Tras capturarla, pide la URL candidata, visita las rutas descubiertas en el router y compara desktop y móvil. `docs/views/_index.md` registra todas las vistas; `docs/views/comparisons/` conserva baseline, candidata y diff únicamente para vistas diferentes.

## Qué genera

En el repo del usuario (nunca en el plugin):

```
docs/migration/
├── _index.md                    ← tabla con todos los saltos completados
├── _errors-knowledge.md         ← base de conocimiento de fixes acumulados
├── v8/
│   ├── v8-why.md                ← qué cambió en Angular 8 y por qué (Cronos)
│   ├── v8-changelog.md          ← versiones, ng update, warnings, build (Clío)
│   └── v8-diff.md               ← diff real del salto (Clío)
└── ...

.angular-migration/              ← gitignorado, artefactos de máquina
├── config.json                  ← configuración global del proyecto
├── state.json                   ← estado global de la migración
├── progress.json                ← progreso visible del salto actual
└── v7-v8.log/                   ← artefactos y logs del salto
	├── snapshot-v8.json         ← versiones actuales vs objetivo
	├── plan-v8.json             ← plan de Prometeo
	├── report-v8.json           ← resultado de Hefesto
	├── changes-v8.json          ← cambios semánticos agrupados
	└── logs/                    ← logs legibles del salto, incluido runtime.log
```

Cada salto crea su rama `migration/v{N}` con commits atómicos por paso.

## Estructura del repo

```
angular-migration-plugin/
├── plugin.json
├── agents/                      ← siete agentes; tres invocables directamente
│   ├── Hermes.agent.md          ← orquestador (@Hermes 17)
│   ├── Cronos.agent.md
│   ├── Prometeo.agent.md
│   ├── Hefesto.agent.md
│   ├── Clio.agent.md
│   ├── Asclepio.agent.md
│   └── Helios.agent.md
├── skills/
│   ├── update-angular/          ← slash command /update-angular
│   │   └── SKILL.md
│   ├── angular-migration/       ← contexto del plugin
│   │   └── SKILL.md
│   ├── karpathy-guidelines/     ← incluida en el plugin
│   │   └── SKILL.md
│   └── ponytail/                ← incluida en el plugin
│       └── SKILL.md
├── scripts/
│   ├── angular-migration.ps1    ← API determinista para los agentes
│   ├── playwright-runtime-check.js ← check de runtime de la migración
│   └── playwright-vision.js     ← capturas y comparación PNG
├── schemas/                     ← contratos JSON de cambios y vistas
├── rules/                       ← catálogo de patrones de Asclepio
├── tests/
│   ├── smoke.ps1                ← smoke rápido del script
│   └── vision-smoke.ps1         ← comparación visual end-to-end local
├── docs/
│   ├── v2-plan.md
│   └── v3-plan.md               ← documento de diseño v3
├── .github/
│   └── plugin/
│       └── marketplace.json
└── README.md
```

## Licencia

MIT

---
name: angular-migration
description: Contexto de migración Angular (v2). Carga este skill cuando trabajes con el plugin angular-migration — proporciona las restricciones de versión, la convención de ramas y la estructura de handoff entre agentes.
user-invocable: false
---

# angular-migration — Contexto del plugin (v2)

## Stack objetivo

Angular 7→17, Ionic 4→7, RxJS 6→7, TypeScript 3→5, zone.js.
NGModules únicamente — sin standalone components ni signals.
Siempre major por major — los schematics de `ng update` solo garantizan saltos consecutivos.

## Convenciones de rama

Cada salto usa `migration/v{N}`, creada por **Hermes** antes del fleet.
Nunca se hace push — solo commits locales hasta el merge manual.

## Estructura de handoff (`.angular-migration/`, gitignorada, en el repo del usuario)

| Fichero                                | Escritor        | Lectores               |
| -------------------------------------- | --------------- | ---------------------- |
| `config.json`                          | script (init)   | Hermes                 |
| `state.json`                           | script          | Hermes                 |
| `v{from}-v{to}.log/snapshot-v{N}.json` | script (Hermes) | Cronos, Prometeo, Clío |
| `v{from}-v{to}.log/plan-v{N}.json`     | Prometeo        | Hefesto, Clío          |
| `v{from}-v{to}.log/report-v{N}.json`   | Hefesto         | Hermes, Clío           |
| `v{from}-v{to}.log/logs/`              | script          | todos (diagnóstico)    |

## Documentación generada (`docs/migration/`, commiteada)

```
docs/migration/
├── _index.md                  ← índice global (Clío)
├── _errors-knowledge.md       ← KB de fixes (Clío escribe, Hefesto lee)
└── v{N}/
    ├── v{N}-why.md            ← porqué del salto (Cronos)
    ├── v{N}-changelog.md      ← registro de ejecución (Clío)
    └── v{N}-diff.md           ← diff real del salto (Clío)
```

## Reglas globales

- Un commit por paso. Nunca acumular.
- Nunca comandos npm/ng/git propios — siempre el script (`ng-update`, `build`, `commit`...).
- Nunca `npx ng update` — el script usa `node_modules/.bin/ng.cmd` local.
- Nunca push automático.
- `.angular-migration/` nunca se commitea.
- El script escribe en el cwd (repo del usuario), nunca en la carpeta del plugin.
- Los warnings del build se clasifican: `resolved` / `accepted` / `deferred`.
- `write-snapshot` siempre conserva `direct_dependencies`, la metadata disponible y `dependency_metadata_failures`; si falta metadata, Hermes pide confirmación antes del fleet y los agentes no inventan datos.
- Cronos debe depositar y Hermes debe leer `docs/migration/v{N}/v{N}-why.md` antes de invocar a Hefesto; tras un reintento fallido, el salto se detiene.
- Node se gestiona automáticamente: `ensure-node` activa el major requerido con fnm/nvm (instala si falta). Solo para al usuario si no hay gestor o falla el switch.
- Runtime: Hermes ejecuta `runtime-install` antes de cambiar al Node de Angular. Instala `playwright@1.62.1` y Chromium en `%LOCALAPPDATA%\angular-migration-plugin\playwright-runtime`, con Node 20+, sin modificar la app. Hefesto ejecuta `runtime-check -StartServer` y `scripts/playwright-runtime-check.js` captura consola, page errors, requests fallidas y respuestas HTTP 4xx/5xx.

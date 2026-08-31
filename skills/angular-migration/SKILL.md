---
name: angular-migration
description: Contexto de migración Angular (v3). Carga este skill cuando trabajes con el plugin angular-migration: pipeline Hermes, ledger agrupado y agentes autónomos Asclepio y Helios.
user-invocable: false
---

# angular-migration — Contexto del plugin (v3)

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
| `progress.json`                        | script (Hermes) | Hermes / usuario       |
| `v{from}-v{to}.log/snapshot-v{N}.json` | script (Hermes) | Cronos, Prometeo, Clío |
| `v{from}-v{to}.log/plan-v{N}.json`     | Prometeo        | Hefesto, Clío          |
| `v{from}-v{to}.log/report-v{N}.json`   | Hefesto         | Hermes, Clío           |
| `v{from}-v{to}.log/changes-v{N}.json`  | Hefesto/script  | Hermes, Clío           |
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
- Todo fichero del diff debe aparecer en el ledger agrupado o en una exclusión justificada. Una transformación repetida usa un grupo y múltiples `occurrences`.
- El script escribe en el cwd (repo del usuario), nunca en la carpeta del plugin.
- Hermes mantiene nueve hitos por salto con el comando `progress`; el script imprime la barra por `stderr` y persiste el ultimo estado en `progress.json`.
- Los warnings del build se clasifican: `resolved` / `accepted` / `deferred`.
- `write-snapshot` siempre conserva `direct_dependencies`, la metadata disponible y `dependency_metadata_failures`; si falta metadata, Hermes pide confirmación antes del fleet y los agentes no inventan datos.
- Cronos debe depositar y Hermes debe leer `docs/migration/v{N}/v{N}-why.md` antes de invocar a Hefesto; tras un reintento fallido, el salto se detiene.
- Node se gestiona automáticamente: `ensure-node` activa el major requerido con fnm/nvm (instala si falta). Solo para al usuario si no hay gestor o falla el switch.
- Runtime: `runtime-install` prepara Playwright, Chromium, pixelmatch y pngjs en `%LOCALAPPDATA%\angular-migration-plugin\playwright-runtime`, con Node 20+, sin modificar la app.

## Agentes autónomos

- **Asclepio** escanea `src/` y aplica únicamente reglas `safe-fix` mecánicas con las herramientas ya declaradas por el repo. No cambia versiones, lógica ni Git.
- **Helios** usa las herramientas del browser integrado de VS Code: el usuario comparte una pestaña base autenticada, Helios descubre y captura todas las rutas; después el usuario comparte una pestaña candidata y Helios repite las capturas y compara. Nunca solicita secretos por chat.
- Ninguno forma parte del fleet de Hermes ni puede ser invocado por Hermes.

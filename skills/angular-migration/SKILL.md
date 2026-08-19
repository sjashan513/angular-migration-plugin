---
name: angular-migration
description: Contexto de migración Angular. Carga este skill cuando trabajes con el plugin angular-migration — proporciona las restricciones de versión, la convención de ramas y la estructura de handoff entre agentes.
user-invocable: false
---

# angular-migration — Contexto del plugin

## Stack objetivo

Angular 7→17, Ionic 4→7, RxJS 6→7, TypeScript 3→5, zone.js.
NGModules únicamente — sin standalone components ni signals.

## Convenciones de rama

Cada salto crea su propia rama: `migration/v{N}`.
Nunca se hace push — solo commits locales hasta el merge manual.

## Estructura de handoff (`.angular-migration/`, gitignorado)

| Fichero            | Escritor      | Lectores      |
| ------------------ | ------------- | ------------- |
| `config.json`      | script (init) | Hermes        |
| `state.json`       | script        | Hermes        |
| `plan-v{N}.json`   | Prometeo      | Hefesto, Clío |
| `report-v{N}.json` | Hefesto       | Clío          |

## Documentación generada (`docs/migration/`, commiteada)

```
docs/migration/
├── _index.md                  ← índice global (Clío)
├── _errors-knowledge.md       ← KB de fixes (Clío escribe, Hefesto lee)
└── v{N}/
    ├── v{N}-why.md            ← porqué del salto (Cronos)
    └── v{N}-changelog.md      ← registro de ejecución (Clío)
```

## Reglas globales

- Un commit por paso. Nunca acumular.
- Nunca `npx ng update` — siempre `.\node_modules\.bin\ng.cmd` vía el script.
- Nunca push automático.
- `.angular-migration/` nunca se commitea.

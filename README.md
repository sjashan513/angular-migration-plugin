# angular-migration — Plugin para GitHub Copilot (v2)

Pipeline de 5 agentes que migra proyectos Angular de v7 a cualquier versión objetivo de forma autónoma, **major por major vía `ng update`**. Tú solo supervisas el arranque.

## Agentes

| Agente       | Rol                                                                            | Modelo          |
| ------------ | ------------------------------------------------------------------------------ | --------------- |
| **Hermes**   | Orquestador. Gates, rama, snapshot de versiones, fleet y verificación.         | GPT-5.6 Luna    |
| **Cronos**   | Documenta el porqué del salto a partir del snapshot.                           | GPT-5.6 Luna    |
| **Prometeo** | Construye el plan ejecutable a partir del snapshot.                            | Grok 4.6 \*     |
| **Hefesto**  | Ejecuta el plan: `ng update` vía script, cambios manuales, build, warnings.    | Claude Sonnet 5 |
| **Clío**     | Consolida la documentación en `docs/migration/` (changelog, diff, índice, KB). | GPT-5.6 Luna    |

\* Requiere activar la policy de Grok 4.6 en Copilot Business/Enterprise. Fallback: edita el frontmatter de `Prometeo.agent.md` y cambia el modelo a `claude-sonnet-5 (copilot)`.

Por cada salto (p. ej. v8→v9): Hermes valida gates, crea la rama, genera el **snapshot de versiones** con el script, lanza un `/fleet` con Cronos y Prometeo en paralelo, invoca a Hefesto para ejecutar el plan y a Clío para documentar.

## Prerequisitos

- GitHub Copilot Business o Enterprise con `/fleet` habilitado
- `chat.subagents.allowInvocationsFromSubagents: true` en VS Code
- PowerShell 5.1+ (Windows) — el script vive en el plugin, no necesitas copiarlo
- Node.js y npm instalados; `fnm` o `nvm` para gestionar versiones de Node

## Instalación

```bash
# Registrar marketplace (solo la primera vez)
copilot plugin marketplace add sjashan513/angular-migration-plugin

# Instalar el plugin
copilot plugin install angular-migration@sjashan513-plugins
```

## Uso

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
3. Un salto falla 3 veces → te expone el historial completo para que decidas.

> **Gestión de Node automática:** cada salto exige un major de Node (p. ej. 10 para Angular 8, 18 para Angular 17). El plugin lo detecta con `fnm` o `nvm`, lo instala si falta y lo activa sin que hagas nada.

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
├── snapshot-v8.json             ← versiones actuales vs objetivo
├── plan-v8.json                 ← plan de Prometeo
├── report-v8.json               ← resultado de Hefesto
└── logs/                        ← logs legibles por salto
```

Cada salto crea su rama `migration/v{N}` con commits atómicos por paso.

## Estructura del repo

```
angular-migration-plugin/
├── plugin.json
├── agents/                      ← los 5 agentes del plugin
│   ├── Hermes.agent.md          ← orquestador (@Hermes 17)
│   ├── Cronos.agent.md
│   ├── Prometeo.agent.md
│   ├── Hefesto.agent.md
│   └── Clio.agent.md
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
│   └── angular-migration.ps1    ← API determinista para los agentes
├── tests/
│   └── smoke.ps1                ← smoke test del script
├── docs/
│   └── v2-plan.md               ← documento de diseño v2
├── .github/
│   └── plugin/
│       └── marketplace.json
└── README.md
```

## Licencia

MIT

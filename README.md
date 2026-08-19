# angular-migration — Plugin para GitHub Copilot

Pipeline de 5 agentes que migra proyectos Angular de v7 a cualquier versión objetivo de forma autónoma. Tú solo supervisas el arranque.

## Agentes

| Agente       | Rol                                                               | Modelo       |
| ------------ | ----------------------------------------------------------------- | ------------ |
| **Hermes**   | Orquestador. Gestiona saltos y fleet.                             | GPT-5.6 Luna |
| **Cronos**   | Investiga qué cambió entre versiones y redacta el doc del porqué. | GPT-5.6 Luna |
| **Prometeo** | Resuelve versiones y construye el plan de ejecución.              | Grok 4.6 \*  |
| **Hefesto**  | Ejecuta el plan sobre el repo (instala, edita, build, commits).   | GPT-5.6 Luna |
| **Clío**     | Consolida la documentación en `docs/migration/`.                  | GPT-5.6 Luna |

\* Requiere activar la policy de Grok 4.6 en Copilot Business/Enterprise. Fallback: edita el frontmatter de `Prometeo.agent.md` y cambia el modelo a `claude-sonnet-5 (copilot)`.

Por cada salto (p. ej. v8→v9), Hermes lanza un `/fleet` con Cronos y Prometeo en paralelo, Hefesto en la segunda oleada y Clío al final.

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
/update 17
```

O directamente con el agente:

```
@Hermes 17
```

Hermes detecta la versión actual, calcula los saltos pendientes (p. ej. 7→8→…→17) y ejecuta la pipeline completa. Solo te parará si:

1. El working tree está sucio → haz commit o stash y confirma.
2. Un salto falla 3 veces → te expone el historial completo para que decidas.

## Qué genera

```
docs/migration/
├── _index.md                    ← tabla con todos los saltos completados
├── _errors-knowledge.md         ← base de conocimiento de fixes acumulados
├── v8/
│   ├── v8-why.md                ← qué cambió en Angular 8 y por qué (Cronos)
│   └── v8-changelog.md          ← versiones instaladas, cambios, build (Clío)
├── v9/
│   ├── v9-why.md
│   └── v9-changelog.md
└── ...
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
│   ├── update/                  ← slash command /update
│   │   └── SKILL.md
│   ├── angular-migration/       ← contexto del plugin
│   │   └── SKILL.md
│   ├── karpathy-guidelines/     ← incluida en el plugin
│   │   └── SKILL.md
│   └── ponytail/                ← incluida en el plugin
│       └── SKILL.md
├── scripts/
│   └── angular-migration.ps1
├── .github/
│   └── plugin/
│       └── marketplace.json
└── README.md
```

## Licencia

MIT

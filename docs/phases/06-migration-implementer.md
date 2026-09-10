# Fase 6 — Agente de reparación controlada

## 1. Resultado de la fase

Esta fase incorpora un único agente capaz de modificar código: `migration-implementer`.
No decide versiones, no inicia migraciones, no ejecuta libremente comandos y no cambia
la máquina de estados. Solo repara un fallo técnico que el controlador determinista ya
ha convertido en `needs-repair`.

El modelo propone y aplica una reparación dentro de un perímetro calculado. El facade
valida el resultado, registra la evidencia y devuelve el control a la misma etapa. La
pipeline, no el agente, vuelve a ejecutar el gate que falló.

```text
pipeline -> needs-repair -> contexto cerrado -> agente -> repair.json
        -> record-repair -> running -> reejecución determinista del gate
```

No se implementa un segundo agente de revisión ni un agente coordinador.

## 2. Superficie soportada

La v5 soporta esta política en GitHub Copilot CLI sobre Windows. Los hooks del plugin
se distribuyen en `hooks.json`; Copilot CLI requiere PowerShell 7 o superior para alojar
hooks en Windows. Esta exigencia no cambia el facade: sus scripts siguen siendo
compatibles con Windows PowerShell 5.1 y también deben funcionar cuando los invoca
PowerShell 7. Copilot cloud agent
queda fuera de alcance: su entorno es Linux, solo descubre por defecto hooks del repo y
no carga los hooks de un plugin instalado como lo hace la CLI.

No declarar soporte parcial para cloud. Si en el futuro se desea, se hará una decisión
separada con una implementación Bash equivalente y sus propios tests.

## 3. Archivos permitidos

Crear:

```text
agents/migration-implementer.agent.md
hooks.json
scripts/hooks/copilot-policy.ps1
schemas/repair-context.schema.json
schemas/repair-input.schema.json
tests/unit/RepairContract.Tests.ps1
tests/unit/CopilotPolicyHook.Tests.ps1
tests/integration/RepairCycle.Tests.ps1
tests/fixtures/hooks/
```

Modificar:

```text
plugin.json
scripts/angular-migration.ps1
scripts/modules/Migration.Pipeline.psm1
scripts/modules/Migration.State.psm1
tests/smoke.ps1
README.md
```

No crear un módulo exclusivo del agente. El contrato pertenece a Pipeline y State; la
política del hook vive en un script pequeño y aislado.

## 4. Comandos públicos

Añadir exactamente:

```powershell
./scripts/angular-migration.ps1 repair-context -RunId <run-id>
./scripts/angular-migration.ps1 record-repair -RunId <run-id> -InputFile <path>
```

`repair-context` es de solo lectura. `record-repair` es la única mutación de estado
permitida después de una intervención del agente.

`-InputFile` no admite una ruta arbitraria. Tras resolverla con `GetFullPath`, debe ser
exactamente:

```text
<project>/.angular-migration/runs/<run-id>/inbox/repair.json
```

Rechazar symlinks, junctions, `..`, alternate data streams y cualquier diferencia de
mayúsculas/minúsculas después de obtener la ruta final de Windows.

## 5. Contrato de repair-context

El comando devuelve el envelope común y en `data` este objeto:

```json
{
  "schemaVersion": 1,
  "runId": "angular-7-to-8-20260910T100000Z-a1b2c3d4",
  "sourceMajor": 7,
  "targetMajor": 8,
  "status": "needs-repair",
  "stage": "validate",
  "failedCheck": "build",
  "fingerprint": "sha256:<64-hex>",
  "attempt": 1,
  "maxAttempts": 3,
  "checkpointCommit": "<40-hex>",
  "manifestSha256": "<64-hex>",
  "allowedPaths": ["src/**/*.ts", "src/**/*.html", "src/**/*.scss"],
  "forbiddenPaths": [
    ".git/**",
    ".angular-migration/**",
    "package.json",
    "package-lock.json",
    "angular.json",
    "scripts/**",
    "hooks.json",
    "agents/**"
  ],
  "diagnostic": {
    "summary": "TypeScript compilation failed",
    "exitCode": 1,
    "logFiles": [".angular-migration/runs/<run-id>/logs/validate-build.stderr.log"],
    "relatedFiles": ["src/app/example.component.ts"],
    "warnings": []
  },
  "submissionPath": ".angular-migration/runs/<run-id>/inbox/repair.json"
}
```

Reglas de construcción:

1. `fingerprint` es SHA-256 de stage, check, exit code, diagnóstico normalizado,
   manifest hash y checkpoint commit.
2. `attempt` empieza en uno y solo incrementa para el mismo fingerprint.
3. `allowedPaths` se deriva del tipo de fallo; nunca procede del prompt.
4. `relatedFiles` es informativo y siempre debe estar contenido en `allowedPaths`.
5. Los logs se referencian; no se incrustan en JSON.
6. Se eliminan tokens, cabeceras, URLs con credenciales y valores de `.npmrc` antes de
   publicar el contexto.
7. El comando falla si state no está en `needs-repair` o el manifest no conserva hash.

Perímetros por gate:

| Gate | Rutas modificables |
| --- | --- |
| `ng-update` | Solo archivos que el log relaciona dentro de `src/`, más `angular.json` únicamente si el controlador marca `configRepairAllowed=true`. |
| `typecheck`, `build`, `test`, `lint` | `src/**/*` y ficheros de configuración que el diagnóstico identifique explícitamente. |
| `npm-install`, integridad, Git, Node o manifest | Ninguna; son bloqueos deterministas y no deben invocar al agente. |

`package.json` y el lockfile nunca son reparables por el agente. Si fallan, hay que
corregir el resolver o detener el run.

## 6. Entrega del agente

El agente escribe un único archivo:

```text
.angular-migration/runs/<run-id>/inbox/repair.json
```

Schema exacto:

```json
{
  "schemaVersion": 1,
  "runId": "angular-7-to-8-20260910T100000Z-a1b2c3d4",
  "fingerprint": "sha256:<64-hex>",
  "attempt": 1,
  "rootCause": "La API eliminada ya no acepta el argumento observado en el error.",
  "changes": [
    {
      "path": "src/app/example.component.ts",
      "summary": "Adapta la llamada a la firma soportada por Angular 8.",
      "reason": "El compilador señala TS2554 en esta llamada."
    }
  ],
  "evidence": [
    {
      "kind": "diagnostic",
      "reference": ".angular-migration/runs/<run-id>/logs/validate-build.stderr.log",
      "claim": "El fallo original corresponde a TS2554."
    }
  ],
  "unresolvedWarnings": []
}
```

No incluir comandos ejecutados, nuevas versiones, flags, estado final, resultados de
tests no ejecutados o texto del tipo “todo funciona”. La pipeline aportará esa evidencia.

## 7. Validación de record-repair

Aplicar todas estas comprobaciones, en este orden:

1. lock activo y ownership del proceso;
2. run id, status `needs-repair`, stage, fingerprint y attempt exactos;
3. schema cerrado: `additionalProperties: false` en todos los objetos;
4. hash actual de manifest igual al de state;
5. HEAD igual a `checkpointCommit` antes de aceptar cambios;
6. diff real obtenido por Git, incluidos untracked, sin confiar en `changes[]`;
7. cada ruta real contenida en `allowedPaths` y ninguna en `forbiddenPaths`;
8. conjunto de rutas de `changes[]` exactamente igual al conjunto real;
9. ausencia de symlinks, submódulos, cambios de modo y renames fuera del perímetro;
10. archivos protegidos y runtime copiado conservan sus hashes;
11. `rootCause`, `summary`, `reason` y `claim` no están vacíos;
12. no se alcanzó `maxAttempts`.

Si falla cualquiera, revertir únicamente archivos tracked modificados desde el
checkpoint y eliminar únicamente untracked creados durante este intento que estén
inventariados en el contexto. No usar `git clean`, no tocar cambios previos del usuario.
Registrar `repair-rejected` y mantener `needs-repair` salvo violación de perímetro, que
deja el run `failed / repair_scope_violation`.

Si pasa:

1. mover `repair.json` a `repairs/<fingerprint>-attempt-<n>.json`;
2. crear commit con mensaje fijo `chore(angular-migration): repair <check> attempt <n>`;
3. guardar commit y hash del informe;
4. registrar `repair-accepted`;
5. cambiar a `running` sin avanzar stage;
6. devolver `nextAction: rerun-failed-check`.

El controlador reejecuta solo el check fallido. Si pasa, continúa los gates restantes.
Si vuelve a fallar con el mismo fingerprint, incrementa attempt. Con tres rechazos o
fallos equivalentes: `blocked / repair_attempts_exhausted`. Un fingerprint nuevo inicia
attempt uno, pero el run admite como máximo cinco reparaciones totales.

## 8. Definición del agente

Crear `agents/migration-implementer.agent.md` con este frontmatter:

```yaml
---
name: migration-implementer
description: Repara exclusivamente un fallo técnico acotado por una migración Angular v5 activa.
tools: [read, search, edit, execute]
user-invocable: false
disable-model-invocation: true
---
```

El cuerpo debe contener, literalmente en términos normativos, estas reglas:

```markdown
Eres el implementador de reparación de Angular Migration v5.

Tu entrada obligatoria es el JSON emitido por `repair-context`. Si no existe, no está
en `needs-repair`, no incluye fingerprint o no coincide con el run solicitado, detente.

Puedes leer el repositorio y los logs referenciados. Puedes editar únicamente rutas
incluidas en `allowedPaths`. `forbiddenPaths` prevalece siempre. No edites dependencias,
lockfiles, Git, el runtime, estado, manifest, informes ni documentación.

No elijas versiones y no ejecutes npm, npx, ng, git, gestores de paquetes, shells ni
comandos arbitrarios. La única ejecución permitida es invocar el facade para obtener
`repair-context` o entregar `record-repair`, usando exactamente los argumentos recibidos.

Corrige la causa mínima demostrada por el diagnóstico. No refactorices, no formatees
archivos ajenos, no añadas dependencias y no arregles warnings no relacionados.

Al terminar, escribe el JSON contractual en `submissionPath` y llama a `record-repair`.
No afirmes que la reparación funciona: la pipeline realizará la verificación.
```

Aunque el perfil incluya `execute` para poder entregar al facade, la política previa a
herramienta debe denegar todo lo demás. Las instrucciones del agente son una ayuda; el
hook y `record-repair` son los límites efectivos.

## 9. Hook de política

El archivo raíz `hooks.json` usa versión 1 y registra `preToolUse` y `subagentStop`.
No usar `postToolUse` para guardar argumentos/resultados completos porque pueden contener
secretos. No depender de `agentStop` para identificar al subagente: `subagentStop` incluye
su nombre y es el evento adecuado.

Durante `start`, el controlador copia una versión inmutable de
`scripts/hooks/copilot-policy.ps1` a:

```text
.angular-migration/runtime/copilot-policy.ps1
```

Guarda su SHA-256 en state. Así, el hook del plugin puede ejecutar una ruta relativa al
repo activo sin depender de una variable de “plugin root” no documentada.

Configuración requerida:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "type": "command",
        "powershell": "if (Test-Path -LiteralPath '.\\.angular-migration\\runtime\\copilot-policy.ps1' -PathType Leaf) { & '.\\.angular-migration\\runtime\\copilot-policy.ps1' -Event preToolUse } else { [Console]::Out.Write('{}') }",
        "cwd": ".",
        "timeoutSec": 10
      }
    ],
    "subagentStop": [
      {
        "type": "command",
        "powershell": "if (Test-Path -LiteralPath '.\\.angular-migration\\runtime\\copilot-policy.ps1' -PathType Leaf) { & '.\\.angular-migration\\runtime\\copilot-policy.ps1' -Event subagentStop } else { [Console]::Out.Write('{}') }",
        "cwd": ".",
        "timeoutSec": 10
      }
    ]
  }
}
```

El wrapper de `hooks.json` devuelve `{}` si el runtime no existe, de modo que instalar el
plugin no bloquea repositorios ajenos. Si el runtime existe pero no hay un run v5 activo,
el script también devuelve `{}`. Con un run activo, lee un solo JSON de stdin y escribe
un solo JSON en stdout, sin banners. Logs internos van a stderr, redactados. Los tests
deben cubrir por separado “runtime ausente” y “runtime presente sin run activo”.

Política `preToolUse`:

- `read` y `search`: permitir salvo credenciales conocidas (`.npmrc`, `.env*`, claves).
- `edit`: extraer todas las rutas de `toolArgs`; denegar si no pueden determinarse, si
  no están en el perímetro activo o si atraviesan un enlace.
- `execute`: permitir únicamente la invocación exacta del facade con `repair-context` o
  `record-repair`, run id activo e input contractual; denegar metacaracteres, comandos
  compuestos, ejecutables alternativos y argumentos adicionales.
- cualquier tool desconocida: denegar.

Salida de denegación:

```json
{
  "permissionDecision": "deny",
  "permissionDecisionReason": "angular-migration-v5: operation outside active repair contract"
}
```

Salida de permiso explícito:

```json
{
  "permissionDecision": "allow",
  "permissionDecisionReason": "angular-migration-v5: operation is inside active repair contract"
}
```

En error interno, terminar con exit code 2 y una razón genérica sin datos sensibles. En
`preToolUse`, esto debe denegar la herramienta. El timeout de hooks es fail-open en
Copilot; por eso `record-repair` vuelve a validar todo y el hook nunca es la única barrera.

Política `subagentStop` para `migration-implementer`:

- permitir si state ya registra `repair-accepted` para fingerprint/attempt;
- bloquear si falta `repair.json`, si no se llamó a `record-repair` o si el agente afirma
  éxito sin registro válido;
- no bloquear otros agentes.

```json
{
  "decision": "block",
  "reason": "Entrega repair.json y regístralo mediante record-repair antes de finalizar."
}
```

## 10. Tests obligatorios

Los tests de hooks invocan el script con JSON fixture por stdin; no arrancan Copilot.
Cubrir al menos:

1. contexto rechazado fuera de `needs-repair`;
2. fingerprint y attempt estables;
3. edit permitido dentro del glob;
4. edit denegado fuera del glob;
5. `forbiddenPaths` prevalece sobre allowed;
6. múltiples paths con uno prohibido deniegan todo;
7. toolArgs desconocido deniega;
8. lectura de `.npmrc` denegada;
9. ejecución exacta de `repair-context` permitida;
10. npm, npx, ng, git y comando compuesto denegados;
11. ausencia de runtime sin run activo devuelve `{}`;
12. error interno de preToolUse termina 2;
13. stdout contiene solo JSON válido;
14. subagentStop bloquea entrega ausente;
15. subagentStop permite reparación registrada;
16. record-repair detecta untracked omitido;
17. detecta rename, symlink, mode change y ruta traversal;
18. detecta package.json o lockfile cambiado;
19. detecta manifest y runtime alterados;
20. acepta cambio mínimo y crea commit fijo;
21. reejecuta únicamente el gate fallido;
22. tercer intento equivalente bloquea;
23. quinto repair total bloquea;
24. rollback conserva cambios previos del usuario.

## 11. Criterio de salida

- [ ] El agente no decide ninguna versión ni transición.
- [ ] Solo existe un agente con permiso de editar código.
- [ ] El contexto y la entrega tienen schemas cerrados.
- [ ] El perímetro se calcula desde evidencia, no desde el prompt.
- [ ] El hook deniega por defecto durante una reparación activa.
- [ ] `record-repair` valida el diff real aunque el hook falle o expire.
- [ ] No se registran secretos ni resultados completos de herramientas.
- [ ] Los reintentos están limitados y son trazables.
- [ ] Una reparación aceptada no se considera válida hasta que pase el gate.
- [ ] Está documentado que v5 soporta Copilot CLI en Windows, no cloud agent.

## 12. Referencias normativas

- GitHub Copilot hooks reference: https://docs.github.com/en/copilot/reference/hooks-reference
- Custom agents configuration: https://docs.github.com/en/copilot/reference/custom-agents-configuration
- Copilot CLI plugin reference: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference

La fase termina únicamente cuando los tests demuestran que un intento malicioso o
accidental no puede modificar una ruta ajena ni registrar una reparación no verificada.

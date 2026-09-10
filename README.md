# angular-migration

Plugin interno para migraciones Angular auditables en Windows con PowerShell 5.1.

## Estado

La fase 3 implementa la inspeccion, el arranque de un unico salto `N -> N+1`
y la baseline interna. Angular actual se obtiene del lockfile; se conservan
el spec declarado, herramientas, configuraciones y checks estructurados.
La resolucion de versiones y la ejecucion de la migracion quedan pendientes.
La fachada sigue exponiendo solamente `inspect`, `start` y `status`.

## Uso

Ejecuta la fachada desde la raiz de un proyecto Angular CLI:

```powershell
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command inspect
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command start -TargetMajor 8
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command status -RunId <run-id>
```

La salida estandar contiene exactamente un JSON v5. Los errores humanos y el progreso se reservan para stderr.

## Precondiciones

- Proyecto Angular CLI con `package.json`, `angular.json` y `package-lock.json` en la raiz.
- npm como gestor de paquetes.
- Raiz Git igual a la del proyecto, HEAD valido, rama no detached y working tree limpio.
- Identidad Git (`user.name` y `user.email`) configurada.
- `.angular-migration/` ignorado por Git.
- Node y npm disponibles.
- El destino debe ser exactamente el major actual mas uno.
- Las aplicaciones necesitan un script npm `build`.

Cada run se guarda bajo `.angular-migration/runs/<run-id>/`. El lock de ownership impide dos runs mutantes sobre el mismo proyecto.

## Baseline interna

`Invoke-MigrationBaseline -ProjectRoot <raiz> -RunId <id>` se importa desde
`Migration.Pipeline.psm1` para las pruebas; no es un comando publico para agentes.
Comprueba ownership, manifest, state y HEAD antes de ejecutar checks.
El orden es `install`, `dependency-tree`, `typecheck`, `lint`, `unit-test`, `build`, `e2e`.
Los dos primeros ejecutan `npm ci` y `npm ls --all`; los restantes usan scripts permitidos.
Un check ausente queda `not-configured`. El primer fallo detiene la secuencia.

Devuelve `passed`, `blocked` o `failed`, los resultados evaluados, `notStarted`
solo en memoria y un diagnostico sin el contenido de logs. Nunca devuelve
`needs-repair`. No cambia la etapa ni libera el lock: la integracion de esas
transiciones pertenece a la fase 5. Los eventos son append-only y los logs
UTF-8 sin BOM quedan en `logs/baseline/` dentro del run.

## Estructura

```text
agents/
  migration-implementer.agent.md
  migration-documenter.agent.md
scripts/
  angular-migration.ps1
  modules/
    Migration.Core.psm1
    Migration.State.psm1
    Migration.Project.psm1
    Migration.Pipeline.psm1
schemas/
  manifest.schema.json
  result.schema.json
tests/
  smoke.ps1
  unit/
    Project.Tests.ps1
    Baseline.Tests.ps1
  fixtures/
docs/
  phases/
```

La instalacion del plugin no escribe artefactos en el propio plugin: la fachada usa el directorio actual como raiz del proyecto.

## Prueba local

```powershell
powershell -NoProfile -File tests\unit\Project.Tests.ps1
powershell -NoProfile -File tests\unit\Baseline.Tests.ps1
powershell -NoProfile -File tests\smoke.ps1
```

Las pruebas usan herramientas controladas y repositorios Git temporales.
No necesitan Node, npm, acceso a internet ni un framework de tests instalado.
El smoke compila un ejecutable Node ficticio con `Add-Type` de PowerShell 5.1.

## Checklist de salida de fase 3

| Invariante                                       | Evidencia automatizada                                                                                          |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Angular procede del lockfile v1/v2/v3            | `Project.Tests.ps1`: versiones declarada/resuelta, ausencia y mismatch                                          |
| Git diferencia raiz, detached, dirty e identidad | `Project.Tests.ps1`: siete codigos de bloqueo                                                                   |
| Checks con executable, arguments, cwd y timeout  | `Project.Tests.ps1`: contrato y prioridad; `Baseline.Tests.ps1`: rechazo de alteraciones                        |
| Aplicacion sin build bloqueada                   | `Project.Tests.ps1`: aplicacion frente a libreria                                                               |
| e2e ausente es not-configured                    | Ambas suites unitarias                                                                                          |
| Baseline en orden fijo                           | `Baseline.Tests.ps1`: traza de procesos fixture                                                                 |
| Baseline rota bloquea, nunca needs-repair        | `Baseline.Tests.ps1`: build y timeout; errores internos failed                                                  |
| Sin shell libre ni interpolacion ejecutable      | Runner usa solo `Invoke-MigrationProcess`; `Baseline.Tests.ps1` rechaza ejecutables, argumentos y cwd alterados |
| Logs fuera de state y stdout                     | `Baseline.Tests.ps1`: dos logs por ejecucion, contenido ausente del resultado y state                           |
| Sin Node/npm/red reales                          | Fixtures de ambas suites; smoke verifica rutas de ejecutables ficticios                                         |
| run sigue sin publicarse                         | `smoke.ps1`: unsupported_command                                                                                |

MIT

# angular-migration

Plugin interno para migraciones Angular auditables en Windows con PowerShell 5.1.

## Estado

La fase 5 ejecuta o reanuda de forma determinista el salto autorizado por el
manifest. Crea una rama dedicada, ejecuta Angular CLI local con versiones
exactas, alinea el lockfile, instala con `npm ci`, valida el proyecto y publica
un resultado tecnico inmutable. No invoca agentes ni genera documentacion final.

## Uso

Ejecuta la fachada desde la raiz de un proyecto Angular CLI:

```powershell
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command inspect
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command start -TargetMajor 8
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command status -RunId <run-id>
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command run -RunId <run-id>
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

## Ejecucion tecnica

`run` obtiene todas sus decisiones de `state.json` y `manifest.json`; no acepta
paquetes, flags, rama ni etapa. Tras la baseline y la resolucion crea
`migration/angular-<origen>-to-<destino>-<sufijo>`, usa exclusivamente
`node_modules/.bin/ng.cmd` y aplica este orden:

```text
ng update con targets exactos
npm install --package-lock-only
npm ci
npm ls --all
typecheck, lint, unit-test, build, e2e
```

El resultado estable es `verified/document`, con el lock mantenido para la fase
documental. Los fallos de codigo con scope seguro producen `needs-repair`; las
precondiciones o incompatibilidades producen `blocked`; los errores internos,
`failed`. Una segunda llamada sobre un resultado verificado no repite procesos.

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

## Resolucion de dependencias

Tras una baseline `passed`, `Invoke-MigrationResolution` resuelve el manifest
pendiente en memoria y lo publica atomicamente bajo
`.angular-migration/runs/<run-id>/manifest.json`. La publicación se relee,
verifica y registra en `state.json`; cualquier sustitucion posterior produce
`manifest_integrity_failed` y un manifest resuelto no puede escribirse de nuevo.
La resolucion utiliza el registry configurado de npm a traves de `npm view`,
sin consultar la red directamente ni publicar credenciales.

## Estructura

```text
agents/
  migration-implementer.agent.md
  migration-documenter.agent.md
scripts/
  angular-migration.ps1
  modules/
    Migration.Core.psm1
    Migration.Dependencies.psm1
    Migration.State.psm1
    Migration.Project.psm1
    Migration.Pipeline.psm1
schemas/
  manifest.schema.json
  state.schema.json
  check-result.schema.json
  change-set.schema.json
  result.schema.json
tests/
  smoke.ps1
  unit/
    Project.Tests.ps1
    Baseline.Tests.ps1
    Dependencies.Tests.ps1
    StateMachine.Tests.ps1
    PackageManifestWriter.Tests.ps1
  integration/
    DependencyResolution.Tests.ps1
    PipelineExecution.Tests.ps1
  fixtures/
docs/
  phases/
```

La instalacion del plugin no escribe artefactos en el propio plugin: la fachada usa el directorio actual como raiz del proyecto.

## Prueba local

```powershell
powershell -NoProfile -File tests\unit\Project.Tests.ps1
powershell -NoProfile -File tests\unit\Baseline.Tests.ps1
powershell -NoProfile -File tests\unit\Dependencies.Tests.ps1
powershell -NoProfile -File tests\unit\StateMachine.Tests.ps1
powershell -NoProfile -File tests\unit\PackageManifestWriter.Tests.ps1
powershell -NoProfile -File tests\integration\DependencyResolution.Tests.ps1
powershell -NoProfile -File tests\integration\PipelineExecution.Tests.ps1
powershell -NoProfile -File tests\smoke.ps1
```

Las pruebas usan herramientas controladas y repositorios Git temporales.
No necesitan npm, acceso a internet ni un framework de tests instalado. La
prueba del renderer requiere Node; el resto usa ejecutables fixture y el smoke
compila uno con `Add-Type` de PowerShell 5.1.

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
| run exige identidad explicita                    | `smoke.ps1`: `run_id_required`                                                                                  |

## Checklist de salida de fase 4

- `Dependencies.Tests.ps1` cubre alineacion Angular, toolchain, peers, Node, specs, metadata y hash canonico.
- `DependencyResolution.Tests.ps1` verifica dos runs independientes, publicacion atomica, inmutabilidad y deteccion de manipulacion.
- El resolver usa solo `npm view` mediante argumentos estructurados y cache por run.
- Todas las dependencias directas conservan seccion y `writeSpec`; los targets publicados son versiones exactas estables.
- La resolucion no modifica archivos de dependencias, codigo fuente ni Git.

## Checklist de salida de fase 5

- `run -RunId` recorre la maquina de estados cerrada hasta `verified/document`.
- Cada operacion persiste inicio, fin correlacionado, logs y postcondiciones.
- Git usa una rama dedicada, checkpoints de rutas exactas y rollback selectivo.
- Angular usa solo la CLI local; no se usa `npx`, CLI global, `git clean` ni push.
- `package.json` pasa por versiones exactas antes de recuperar los rangos declarados.
- El lockfile y todas las dependencias directas se verifican contra el manifest.
- `npm ci`, `npm ls --all` y los checks finales se ejecutan en orden fijo.
- El resultado tecnico tiene hash, es inmutable y mantiene el lock para documentacion.
- La integracion simulada cubre reanudacion, rollback, rutas protegidas y rerun idempotente.

MIT

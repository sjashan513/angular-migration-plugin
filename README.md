# angular-migration

Plugin interno para migraciones Angular auditables en Copilot CLI sobre Windows.
El facade es compatible con Windows PowerShell 5.1; los hooks de Copilot CLI
requieren PowerShell 7 o superior. Copilot cloud agent no esta soportado.

## Estado

La fase 6 incorpora reparaciones controladas sobre el salto autorizado por el
manifest. Crea una rama dedicada, ejecuta Angular CLI local con versiones
exactas, alinea el lockfile, instala con `npm ci`, valida el proyecto y publica
un resultado tecnico inmutable. `migration-implementer` recibe un contexto
cerrado; no decide versiones ni transiciones. La documentacion final sigue
reservada para la fase documental.

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

## Reparacion controlada

Un fallo tecnico con perimetro seguro deja el run en `needs-repair`. `run` no
reanuda ese estado por si solo. El controlador entrega al implementador el
contexto y las invocaciones exactas, usando la ruta absoluta instalada del facade:

```powershell
& '<plugin>\scripts\angular-migration.ps1' repair-context -RunId <run-id>
& '<plugin>\scripts\angular-migration.ps1' record-repair -RunId <run-id> -InputFile '.angular-migration/runs/<run-id>/inbox/repair.json'
```

`repair-context` no escribe estado. Su envelope usa `status: needs-repair` y
exit code 2 aunque el contexto se haya obtenido correctamente. El agente solo
puede editar `allowedPaths`, salvo el archivo contractual `submissionPath`.
No puede ejecutar herramientas de build ni comandos arbitrarios. Los nombres
de herramienta desconocidos se deniegan; `edit`/`create` usan rutas explicitas,
y las lecturas/busquedas rechazan credenciales y enlaces. El hook deniega
busquedas recursivas cuyo directorio contenga credenciales o enlaces.

`record-repair` exige ownership exclusivo de proceso, schema cerrado, identidad
del intento, manifest y HEAD intactos, diff real coincidente con el informe,
rutas canonicas sin enlaces, modos validos y hashes protegidos. Rechaza informes
con datos sensibles detectables. Aceptar crea un commit de rutas exactas y
devuelve `running / rerun-failed-check`, nunca `verified`.

El controlador, fuera del subagente, ejecuta `run` para repetir el check fallido
y continuar con los restantes. Los checks y comandos Angular anteriores ya
confirmados no se repiten. El runtime del hook se copia durante `start` y su
SHA-256 se guarda en state; el plugin registra `preToolUse` y `subagentStop`.
No se guardan argumentos ni resultados completos de herramientas.

Tres rechazos o fallos equivalentes bloquean el run con
`repair_attempts_exhausted`; se permiten como maximo cinco intervenciones
totales. El quinto cambio aceptado aun debe pasar su gate y no habilita un sexto.
Un diagnostico nuevo empieza en intento uno. Como el checkpoint cambia tras
cada commit aceptado, el fingerprint contractual tambien cambia: el presupuesto
de fallos equivalentes se conserva mediante la identidad del diagnostico sin
checkpoint. Reconsultar el mismo contexto no altera fingerprint ni intento.

Los informes se archivan como `repairs/<digest>-attempt-<n>.json`, donde
`digest` es el hexadecimal del fingerprint sin `sha256:` (el colon no es un
nombre de archivo valido en Windows). El rollback restaura solo tracked del
intento y elimina solo untracked inventariados por el hook antes de crearlos.
Los untracked no inventariados y cambios previos del usuario se conservan;
pueden requerir revision manual antes de continuar. Un lock de registro dejado
por un proceso interrumpido requiere confirmar que ese proceso termino antes
de retirarlo manualmente.

### Limite de seguridad

La garantia es detectar y rechazar entregas indebidas, con rollback selectivo;
no es impedir absolutamente toda escritura previa. Los timeouts de hooks son
fail-open y estos archivos pertenecen al mismo usuario del sistema operativo.
El estado del controlador y su instalacion son la base de confianza. Un proceso
con acceso arbitrario a esos archivos no queda aislado por este plugin. Para
esa garantia se necesita una sandbox o separacion de permisos externa.

La configuracion es exclusivamente para Copilot CLI en Windows: no hay
implementacion Bash ni soporte parcial para cloud agent. Las pruebas del hook
usan fixtures JSON por stdin, sin arrancar Copilot. Contrato, hook, ciclo de
reparacion y pipeline verificados en Windows PowerShell 5.1 y PowerShell 7.6.6.
La lectura JSON conserva timestamps como texto cuando el runtime lo permite,
para mantener estables los hashes del manifest y del resultado entre runtimes.

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
powershell -NoProfile -File tests\unit\RepairContract.Tests.ps1
powershell -NoProfile -File tests\unit\CopilotPolicyHook.Tests.ps1
powershell -NoProfile -File tests\integration\RepairCycle.Tests.ps1
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

# Plan de finalización de angular-migration v5

Para una lectura narrativa del recorrido completo, consulta [flujo-del-pipeline.md](flujo-del-pipeline.md). Ese documento resume como se relacionan la fachada, el controlador, los agentes, los checkpoints, los estados y la documentacion final.

## 1. Propósito

Esta carpeta es el contrato de implementación de las fases que faltan para convertir el esqueleto actual de `angular-migration` en una pipeline completa de migración Angular. Sustituye toda la documentación anterior. Los documentos históricos, auditorías y candidatos de ADR eliminados no deben utilizarse como fuente de comportamiento.

La intención es que un implementador pueda completar cada fase sin decidir arquitectura, comandos, estados, permisos o criterios de aceptación. Si el código actual contradice estos documentos, el implementador debe detener esa fase y registrar la contradicción; no debe inventar una tercera alternativa.

## 2. Estado de partida

Se considera ya implementado y fuera del trabajo restante:

- fachada PowerShell 5.1 con `inspect`, `preflight`, `discover`, `approve-runtime-install`, `start`, `run`, `status`, `skip-check` y `skip-checks`;
- módulos `Migration.Core.psm1`, `Migration.State.psm1`, `Migration.Project.psm1` y `Migration.Pipeline.psm1`;
- detección de proyecto Angular CLI npm en la raíz;
- inventario de dependencias directas;
- descubrimiento inicial de checks;
- salto obligatorio `N -> N+1`;
- working tree Git limpio;
- `.angular-migration/` ignorado por Git;
- lock exclusivo por proyecto;
- identificadores de run no predecibles;
- JSON atómico;
- argumentos de proceso estructurados;
- smoke tests de inspect, discover, start, status, concurrencia y estado corrupto;
- dos perfiles: Migration Implementer y Migration Documenter;
- ausencia de Playwright en el flujo principal.

Las fases de ejecución y discovery ya están integradas: `discover` persiste el plan de repositorio y runtimes, `start` crea el run después de validarlo y `run` ejecuta las etapas deterministas, incluidos `ng update`, la resolución de dependencias y los checks.

## 3. Principios no negociables

Todas las fases deben respetar estas reglas:

1. Cada run migra exactamente una major elegida por el usuario: `targetMajor == sourceMajor + 1`.
2. La fachada `scripts/angular-migration.ps1` es la única API que pueden invocar los agentes.
3. El controlador decide versiones, ejecutables, argumentos, orden de etapas y transiciones.
4. Los agentes nunca fabrican comandos `npm`, `npx`, `ng` o `git`.
5. No se permite `--force`, `--allow-dirty`, `--legacy-peer-deps`, `--ignore-scripts` ni equivalentes que cambien la semántica de validación.
6. Solo se soportan npm, `package-lock.json`, proyectos Angular CLI en la raíz y repositorios Git no monorepo.
7. Yarn, pnpm, npm workspaces, Nx, aliases npm, dependencias Git, URLs, `file:`, `link:`, `workspace:` y `patch:` producen `blocked` hasta que exista una política específica.
8. Toda escritura contractual pasa por una función atómica y valida `schemaVersion`, `runId` y ownership.
9. Un artefacto de otro run nunca autoriza una transición.
10. Un check ausente es `not-configured`; nunca es `passed`.
11. Un fallo previo a la migración es `blocked`; un fallo de código provocado o revelado después de la migración es `needs-repair`; un fallo interno del plugin es `failed`.
12. Un error de documentación no invalida una migración técnicamente `verified`.
13. No se instala ni ejecuta Playwright, Chromium, Pixelmatch, PNGJS ni otro runtime visual.
14. El controlador no hace push, merge ni crea pull requests.
15. Los hooks son defensa adicional. Las mismas restricciones deben existir dentro de la fachada y los módulos.

## 4. Secuencia obligatoria

Las fases se implementan en este orden:

1. `03-inspeccion-y-baseline.md`: los checks del
   proyecto se ejecutan de forma normalizada y la baseline impide migrar un proyecto
   ya roto.
2. `04-resolucion-de-dependencias.md`: existe
   un manifest exacto, completo, auditable e inmutable.
3. `05-ejecucion-determinista.md`: `run` lleva el
   proyecto hasta `verified`, `needs-repair`, `blocked` o `failed` y puede reanudarse.
4. `06-migration-implementer.md`: el Implementer
   solo repara archivos autorizados y no controla la pipeline.
5. `07-migration-documenter.md`: el Documenter
   investiga en paralelo y publica únicamente después de `verified`.
6. `08-integracion-y-release.md`: un piloto
   Angular 7 -> 8 completa el flujo y el plugin queda preparado para uso interno.
7. `09-discovery-runtimes-y-skips-batch.md`:
   Discovery persiste el repositorio, resuelve runtimes Node por operación y permite
   aprobar skips en batch.
8. `10-historial-de-reparacion.md`: cada
   fingerprint dispone de un `repair.jsonl` local como contrato documental para
   evitar reparaciones repetidas sin saturar state o events.

No se empieza una fase si la anterior no cumple su checklist de salida. No se mezclan en un mismo cambio tareas de dos fases salvo que una prueba de la fase anterior necesite un fixture que pertenezca a la siguiente; en ese caso, el fixture debe ser mínimo y no contener lógica futura.

Las fases 9 y 10 son incrementos posteriores al cierre inicial de v5. Cuando entren en
implementación, sus contratos sustituyen las restricciones anteriores que exigían un
único Node activo, prohibían instalar runtimes aprobados o conservaban todo el detalle
de intentos de reparación en `state.json` y `events.jsonl`.

## 5. API pública final

La fachada expone estos comandos:

```text
inspect
preflight
discover
approve-runtime-install
start
run
status
skip-check
skip-checks
repair-context
record-repair
documentation-context
record-documentation
```

Contrato de cada comando:

- `preflight` e `inspect` son lecturas de diagnóstico y no requieren run.
- `discover -TargetMajor N` persiste `repo.json` sin crear run; `start` lo exige en
  estado `ready` y con el mismo fingerprint.
- `approve-runtime-install -TargetMajor N -ProposalHash HASH -Confirmed` es mutante
  sobre el inventario de fnm y solo acepta la propuesta vigente.
- `start -TargetMajor N` crea un run `N-1 -> N`, adquiere ownership y persiste el
  input inicial.
- `run -RunId ID` ejecuta o reanuda etapas deterministas con un run activo.
- `status -RunId ID` lee el estado y el ultimo diagnostico.
- `skip-checks -RunId ID -InputFile PATH -Confirmed` registra atomicamente un conjunto
  de omisiones opcionales durante `running/baseline`.
- `skip-check -RunId ID -CheckId ID -Reason TEXT -Confirmed` conserva la recuperación
  individual de un único fallo baseline.
- `repair-context`, `record-repair`, `documentation-context` y
  `record-documentation` entregan o registran artefactos controlados dentro de un run.

Ningún comando público acepta versiones de paquetes, nombres de ejecutables, argumentos libres, ramas, mensajes de commit, rutas de log o estados elegidos por un agente.

## 6. Envelope común

Todo comando escribe exactamente un JSON comprimido en stdout:

```json
{
  "schemaVersion": 5,
  "command": "run",
  "ok": false,
  "status": "needs-repair",
  "data": {},
  "error": null
}
```

Códigos de salida:

- `0`: operación correcta; estados `ready`, `running`, `verified` o `completed`.
- `1`: error interno o estado `failed`.
- `2`: acción humana necesaria; estados `blocked` o `needs-repair`.

Stdout no contiene progreso, warnings ni logs. Todo mensaje humano va a stderr. Los outputs completos de herramientas externas se guardan en `logs/` y el envelope solo devuelve rutas relativas y resúmenes.

## 7. Máquina de estados final

Estados del run:

```text
running
needs-repair
verified
completed
blocked
failed
```

Etapas:

```text
baseline
resolve
update-angular
update-dependencies
install
validate
document
done
```

Transiciones permitidas:

```text
running/baseline            -> running/resolve
running/resolve             -> running/update-angular
running/update-angular      -> running/update-dependencies
running/update-dependencies -> running/install
running/install             -> running/validate
running/validate            -> verified/document
running/*                   -> needs-repair/misma etapa
running/*                   -> blocked/misma etapa
running/*                   -> failed/misma etapa
needs-repair/*              -> running/misma etapa, solo tras record-repair válido
verified/document           -> completed/done, solo tras record-documentation válido
verified/document           -> verified/document si falla la documentación
```

Un bloqueo `blocked/baseline` causado por `typecheck`, `lint`, `unit-test` o `e2e`
puede volver a `running/baseline` mediante `skip-check` o `skip-checks`, siempre con
confirmación explícita y razones no vacías. `install`,
`dependency-tree` y `build` son críticos y no tienen transición de skip. La aprobación
se conserva en `state.json` y `events.jsonl`; el check omitido produce `status:
skipped` sin ejecutar su comando.

No se permite:

- retroceder una etapa confirmada;
- cambiar source o target después de `start`;
- reutilizar un run `blocked` o `failed` como un run nuevo;
- completar sin `migrationStatus: verified` y `documentationStatus: completed`;
- liberar el lock en `needs-repair` o mientras la documentación está pendiente;
- mantener el lock después de `completed`, `blocked` definitivo o `failed` definitivo.

## 8. Layout final de artefactos

```text
.angular-migration/
  active.lock
  runs/
    {runId}/
      manifest.json
      state.json
      events.jsonl
      result.json
      research.json
      repair-history/
        {fingerprint-sin-prefijo}/repair.jsonl
      repairs/
      inbox/
        repair.json
        documentation.json
      logs/
        baseline/
        resolve/
        update-angular/
        update-dependencies/
        install/
        validate/
```

`manifest.json` puede pasar una sola vez de `resolutionStatus: pending` a `resolutionStatus: resolved`. Al resolverlo se calcula `manifestSha256`; después de guardar ese hash en `state.json`, cualquier intento de reemplazar el manifest produce `manifest_immutable`.

`state.json` es el único resumen mutable. `events.jsonl` es append-only. `result.json` se vuelve inmutable cuando `migrationStatus` alcanza `verified`. `research.json` puede actualizarse durante la investigación, pero la versión final queda asociada por hash cuando se completa la documentación.

Cada fingerprint de reparación tiene un `repair.jsonl` independiente bajo el run. Sus
entradas tienen schema cerrado, `sequence`, `entryId` y `entrySha256`; el controlador
es el único que añade líneas y el hook solo permite al Implementer leer el archivo
exacto del contexto activo. `state.json` conserva mirrors y summaries compactos, y
`events.jsonl` conserva únicamente hitos globales como `repair-required`,
`repair-accepted` y `repair-exhausted`.

El historial se retiene hasta archivar el run. Se redactan secretos, credenciales,
rutas absolutas y texto excesivo; no se persisten prompts, tool calls, diffs ni logs
completos. `submission-accepted` significa que el diff fue validado y committed, no
que el gate haya pasado. Solo `verification-passed` hace efectiva la reparación para
`result.json` y la documentación final.

## 9. Definition of Done global

El producto se considera terminado únicamente cuando:

- `/update-angular 8` aplicado a un fixture Angular 7 crea un único run 7 -> 8;
- todas las versiones instaladas proceden del manifest resuelto;
- todas las dependencias directas quedan actualizadas o bloqueadas con una razón concreta;
- el controlador no contiene flags de bypass;
- baseline y checks finales son reproducibles;
- una baseline rota no modifica `package.json` ni `package-lock.json`;
- una ejecución interrumpida reanuda desde el último checkpoint confirmado;
- un fallo reparable entrega al Implementer un scope explícito;
- una reparación aceptada conserva su contexto hasta que el gate registre
  `verification-passed`;
- una interrupción entre append, commit, state y transición se reconcilia sin repetir
  mutaciones; historial corrupto o evidencia ambigua bloquea el run;
- el cuarto intento del mismo fingerprint se bloquea;
- el Documenter puede investigar después de resolver el manifest y antes de finalizar la migración;
- la documentación final no se publica antes de `verified`;
- un fallo documental mantiene `migrationStatus: verified`;
- los hooks bloquean comandos libres y escrituras fuera de scope;
- los módulos vuelven a validar las restricciones aunque los hooks estén deshabilitados;
- no quedan runners, fixtures ni referencias funcionales visuales;
- tests unitarios, integración y smoke pasan en Windows PowerShell 5.1;
- el piloto Angular 7 -> 8 termina en `completed` o en un `blocked` cuya causa y siguiente acción estén completas.

## 10. Regla para el implementador

Al ejecutar estos documentos, el implementador debe:

1. leer por completo el documento de la fase;
2. comprobar sus precondiciones;
3. modificar únicamente los archivos listados;
4. implementar los pasos en el orden indicado;
5. añadir primero los tests que demuestran cada invariante;
6. no implementar tareas de fases posteriores;
7. detenerse si una decisión no está expresada aquí;
8. entregar el checklist de salida con evidencia por punto.

“Funciona manualmente” no es evidencia suficiente. Cada transición, bloqueo y restricción debe estar cubierta por un test automatizado o por una validación de schema reproducible.

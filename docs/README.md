# Plan de finalización de angular-migration v5

## 1. Propósito

Esta carpeta es el contrato de implementación de las fases que faltan para convertir el esqueleto actual de `angular-migration` en una pipeline completa de migración Angular. Sustituye toda la documentación anterior. Los documentos históricos, auditorías y candidatos de ADR eliminados no deben utilizarse como fuente de comportamiento.

La intención es que un implementador pueda completar cada fase sin decidir arquitectura, comandos, estados, permisos o criterios de aceptación. Si el código actual contradice estos documentos, el implementador debe detener esa fase y registrar la contradicción; no debe inventar una tercera alternativa.

## 2. Estado de partida

Se considera ya implementado y fuera del trabajo restante:

- fachada PowerShell 5.1 con `inspect`, `start` y `status`;
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
- smoke tests de inspect, start, status, concurrencia y estado corrupto;
- dos perfiles: Migration Implementer y Migration Documenter;
- ausencia de Playwright en el flujo principal.

El estado actual todavía no migra ningún proyecto. `start` crea el run y conserva el lock, pero no resuelve versiones, no ejecuta `ng update`, no actualiza el resto de dependencias y no ejecuta checks.

## 3. Principios no negociables

Todas las fases deben respetar estas reglas:

1. Cada run migra exactamente una major: `targetMajor == sourceMajor + 1`.
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

| Orden | Documento | Resultado exigido |
| --- | --- | --- |
| 3 | [03-inspeccion-y-baseline.md](phases/03-inspeccion-y-baseline.md) | Los checks del proyecto pueden ejecutarse de forma normalizada y la baseline impide migrar un proyecto ya roto. |
| 4 | [04-resolucion-de-dependencias.md](phases/04-resolucion-de-dependencias.md) | Existe un manifest exacto, completo, auditable e inmutable. |
| 5 | [05-ejecucion-determinista.md](phases/05-ejecucion-determinista.md) | `run` lleva el proyecto hasta `verified`, `needs-repair`, `blocked` o `failed` y puede reanudarse. |
| 6 | [06-migration-implementer.md](phases/06-migration-implementer.md) | El Implementer solo repara archivos autorizados y no controla la pipeline. |
| 7 | [07-migration-documenter.md](phases/07-migration-documenter.md) | El Documenter investiga en paralelo y publica únicamente después de `verified`. |
| 8 | [08-integracion-y-release.md](phases/08-integracion-y-release.md) | Un piloto Angular 7 -> 8 completa el flujo y el plugin queda preparado para uso interno. |

No se empieza una fase si la anterior no cumple su checklist de salida. No se mezclan en un mismo cambio tareas de dos fases salvo que una prueba de la fase anterior necesite un fixture que pertenezca a la siguiente; en ese caso, el fixture debe ser mínimo y no contener lógica futura.

## 5. API pública final

La fachada debe terminar con exactamente estos comandos:

```text
inspect
start
run
status
repair-context
record-repair
documentation-context
record-documentation
```

Contrato de cada comando:

| Comando | Mutante | Requiere run activo | Finalidad |
| --- | --- | --- | --- |
| `inspect` | No | No | Inspeccionar precondiciones sin escribir. |
| `start -TargetMajor N` | Sí | No | Crear un run `N-1 -> N`, adquirir lock y persistir el input inicial. |
| `run -RunId ID` | Sí | Sí | Ejecutar o reanudar etapas deterministas. |
| `status -RunId ID` | No | No | Leer estado y último diagnóstico. |
| `repair-context -RunId ID` | No | Sí | Entregar al Implementer el fallo y las rutas editables. |
| `record-repair -RunId ID -InputFile PATH` | Sí | Sí | Validar el informe del Implementer y autorizar una reanudación. |
| `documentation-context -RunId ID` | No | Sí | Entregar inputs verificables al Documenter. |
| `record-documentation -RunId ID -InputFile PATH` | Sí | Sí | Validar investigación/documentación y actualizar el estado documental. |

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

| Código | Significado |
| --- | --- |
| `0` | Operación correcta; estados `ready`, `running`, `verified` o `completed`. |
| `1` | Error interno o estado `failed`. |
| `2` | Acción humana necesaria; estados `blocked` o `needs-repair`. |

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

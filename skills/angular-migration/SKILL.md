---
name: angular-migration
description: Orquesta una migracion Angular v5 de una major por ejecucion.
argument-hint: ProjectRoot y, opcionalmente, la major objetivo
user-invocable: true
---

# Angular Migration v5

Esta skill es el unico punto de entrada conversacional del plugin. Coordina la fachada
y los dos agentes declarados por el plugin; no edita el repositorio, no elige versiones
y no ejecuta gates por su cuenta.

## Contrato de trabajo

- Si `ProjectRoot` no aparece en la peticion, solicitalo antes de ejecutar nada.
- Ejecuta la fachada con `-ProjectRoot` explicito para conservar rutas con espacios.
- Cada salida de la fachada es un unico envelope JSON. Usa `status`, `data` y `error`
  de ese envelope; nunca conviertas el texto de un subagente en estado del run.
- No aceptes decisiones de dependencias, cambios de alcance, ramas, comandos o estados
  en lenguaje natural.
- Si un artefacto no coincide con su contexto, informa el bloqueo y detente.

## Secuencia

1. Ejecuta `inspect` y muestra sus bloqueos sin corregirlos automaticamente:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 inspect -ProjectRoot <ProjectRoot>
   ```

2. Si `inspect` no devuelve `status=ready`, termina con `blocked` usando los
   `blockers` del envelope. No invoques agentes para resolver precondiciones.

3. Pide confirmacion explicita antes de `start`. Explica que el run crea la rama de
   migracion, copia el runtime del hook y crea commits controlados.

4. Tras confirmar, calcula la major objetivo solo desde `inspect.data.angular.currentMajor`
   y exige que sea exactamente una major posterior. Ejecuta:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 start -TargetMajor <target> -ProjectRoot <ProjectRoot>
   ```

   Conserva el `runId` del envelope. Si `start` no devuelve `status=running`, informa
   `blocked` o `failed` desde su resultado y no continues.

   Cuando `start` devuelva `status=running`, comunica al usuario: "Todo esta listo para
   ejecutar la migracion. A partir de ahora trabajare autonomamente, sin pedir
   supervision en cada etapa. Solo me detendre si el controlador detecta un bloqueo,
   un fallo o necesita una reparacion tecnica acotada." No pidas otra confirmacion para
   cada stage.

5. Ejecuta `run` con el `runId` conservado como un unico proceso de fachada que pueda
   mantenerse en curso y consulta `status` mientras avanza. No invoques un segundo
   `run` para sondear ni para reemplazar al proceso original. El proceso principal
   debe conservar su salida hasta terminar y usar el mismo `runId` en todas las
   consultas.

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 run -RunId <run-id> -ProjectRoot <ProjectRoot>
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 status -RunId <run-id> -ProjectRoot <ProjectRoot>
   ```

   Si `run` termina en `blocked` con `error.code=baseline_check_failed`,
   `error.details.checkId=dependency-tree`, ejecuta:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 baseline-dependency-context -RunId <run-id> -ProjectRoot <ProjectRoot>
   ```

   Presenta cada elemento de `data.packages` con su nombre y version exacta,
   `requiredRange`, `requiredBy` y `reason`. Explica que son dependencias peer que npm
   ha marcado como ausentes y que se instalaran como dependencias directas para que el
   arbol existente pase antes de iniciar la migracion. Explica tambien que no se
   cambiara ningun paquete Angular en esta operacion y que `npm ls --all` verificara el
   resultado.

   Pide una confirmacion explicita y espera la respuesta. No instales nada ante una
   respuesta ambigua o negativa. Solo despues de un "si" usa el `proposalHash` devuelto:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 approve-baseline-dependencies -RunId <run-id> -ProposalHash <proposal-hash> -Confirmed -ProjectRoot <ProjectRoot>
   ```

   Esta operacion instala las versiones exactas, ejecuta `npm ls --all`, crea un commit
   controlado y devuelve `nextAction=inspect-and-start-new-run`. Si falla, informa el
   bloqueo y no intentes reanudar el run antiguo.

   Tras un resultado `ready`, ejecuta `inspect`, crea automaticamente un run nuevo con
   el mismo objetivo secuencial ya confirmado y vuelve a anunciar que todo esta listo y
   que continuaras autonomamente. La confirmacion de dependencias y la confirmacion
   inicial de `start` son las unicas confirmaciones humanas de este flujo.

6. Para research, solo despues de observar `status.data.resolutionStatus=resolved`,
   ejecuta `documentation-context -Mode research`, entrega ese JSON al documenter y
   deja que escriba exclusivamente `allowedWritePath`. Lanza el documenter mientras
   continua el proceso original de `run`; la investigacion debe empezar antes de que
   el estado llegue a `verified`. Cuando el proceso de `run` termine en un estado
   estable y el agente haya entregado el JSON, registra su `research.json` con
   `record-documentation -Mode research`. El registro se hace desde el controlador,
   nunca desde el agente, para evitar escrituras concurrentes sobre `state.json`; no
   publica documentos finales.

7. Si el estado llega a `needs-repair`, ejecuta `repair-context` y lanza
   `migration-implementer` exactamente una vez para la pareja `fingerprint/attempt`.
   Rechaza cualquier intento de ampliar `allowedPaths` o modificar una ruta prohibida.
   El implementer entrega `repair.json` y registra la reparacion mediante la fachada.
   No lances otro implementer para el mismo contexto.

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 repair-context -RunId <run-id> -ProjectRoot <ProjectRoot>
   ```

8. Solo despues de que `record-repair` devuelva un envelope valido, reanuda `run` con
   el mismo `runId`. Nunca ejecutes manualmente un gate, ni aceptes `verified` desde el
   agente. Si aparece un nuevo fingerprint, tratalo como un nuevo intento controlado.

9. Cuando `migrationStatus=verified`, exige que research este registrado y emite
   `documentation-context -Mode publish`. Lanza `migration-documenter` en modo publish
   solo entonces. Publish y reparacion son secuenciales; no se solapan.

10. Tras la entrega del documenter, registra `documentation.json` con
    `record-documentation -Mode publish`. La fachada valida los ocho archivos, hashes,
    enlaces, claims y commits. La skill no ejecuta validaciones alternativas.

11. Consulta `status` una ultima vez y comunica unicamente el estado del artefacto:
    `completed`, `blocked` o `failed`. Solo `state.status=completed` permite declarar
    exito. Conserva `runId`, rutas de state/result y el diagnostico final.

## Reglas de agentes

- `migration-implementer` solo interviene en `needs-repair`, con el contexto emitido
  por `repair-context`, y una vez por `fingerprint/attempt`.
- `migration-documenter` usa research antes de verified y publish despues de verified.
- El documenter no ejecuta comandos ni cambia dependencias, configuracion, estado,
  manifest, resultado o logs.
- Si cualquiera de los agentes pide una ruta, herramienta o alcance no incluido en su
  contexto, no lo autorices: registra el bloqueo desde el envelope del controlador.
- Ningun agente instala dependencias baseline. Esa accion pertenece exclusivamente a
  `approve-baseline-dependencies` despues de la confirmacion del usuario.
- Un agente no puede liberar el lock ni cambiar el estado final.

## Recuperacion

Ante una interrupcion, consulta `status` con el mismo `runId` y reanuda `run` solo si
el lock pertenece a un proceso que ya termino. Un run en `needs-repair` requiere una
entrega aceptada antes de reanudar. Un run bloqueado por `dependency-tree` requiere
`baseline-dependency-context`, confirmacion y `approve-baseline-dependencies`; despues
se crea un run nuevo. Un run `verified` espera publish; un run `completed` es terminal.
No crees un segundo run salvo para sustituir explicitamente ese baseline bloqueado.

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

### Diagnostico previo read-only

Antes de crear un run, puedes ejecutar el diagnostico exhaustivo para obtener todos
los bloqueos de dependencias en una sola pasada:

```powershell
powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 resolve-diagnostics -TargetMajor <target> -ProjectRoot <ProjectRoot>
```

`resolve-diagnostics` no crea run, rama, estado, discovery persistente ni manifest;
tampoco modifica `package.json`, el lockfile o el proyecto. Si devuelve
`status=blocked` con `data.diagnostic`, presenta conjuntamente `conflicts`,
`warnings` y `proposals`; cada elemento conserva su `package`, `stage`, `code` y
`details` cuando corresponda. El informe incluye `inputFingerprint`,
`discoverySha256`, `diagnosticSha256` y `queryEvents` para reproducir y verificar la
consulta. Los conflictos se acumulan y se ordenan de forma determinista, por lo que
no debes relanzar el comando para descubrir el siguiente bloqueo. Si el fingerprint
cambia, vuelve a ejecutar el diagnostico antes de usar sus decisiones. Un resultado
`status=ready` solo indica que la propuesta read-only no encontro conflictos; aun asi
debes ejecutar `discover` antes de `start`.

1. Determina la major objetivo. Si la peticion no la incluye, ejecuta `inspect` solo
   para leer `data.angular.currentMajor` y usa exactamente la major siguiente; `inspect`
   no sustituye a `discover`. Ejecuta despues `discover` antes de crear cualquier run:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 discover -TargetMajor <target> -ProjectRoot <ProjectRoot>
   ```

   Si `discover` no devuelve `status=ready` porque falta un runtime, presenta
   `data.installProposal` con cada version exacta, sus perfiles, razones y
   `proposalHash`. Explica que solo modifica el inventario local de fnm, no el
   repositorio, y que no ejecuta `fnm use` ni `fnm default`. Pide una unica
   confirmacion explicita. Ante una respuesta ambigua o negativa, termina en
   `blocked` sin instalar nada.

   Solo despues de confirmar ejecuta:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 approve-runtime-install -TargetMajor <target> -ProposalHash <proposal-hash> -Confirmed -ProjectRoot <ProjectRoot>
   ```

   `approve-runtime-install` valida el fingerprint y la propuesta vigente, instala
   unicamente las versiones exactas y vuelve a ejecutar discovery. Si no devuelve
   `status=ready`, informa el bloqueo y no invoques `start`. Cualquier otro
   `status=blocked` de `discover` tambien detiene el flujo.

2. Cuando discovery devuelva `status=ready`, pide confirmacion explicita antes de
   `start`. Explica que el run crea la rama de migracion, copia el runtime del hook y
   crea commits controlados. Ejecuta:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 start -TargetMajor <target> -ProjectRoot <ProjectRoot>
   ```

   Conserva el `runId` del envelope. Si `start` no devuelve `status=running`, informa
   `blocked` o `failed` desde su resultado y no continues.

3. Tras un `start` correcto, presenta una sola vez todos los checks opcionales
   configurados (`typecheck`, `lint`, `unit-test`, `e2e`). Explica que `install`,
   `dependency-tree` y `build` son gates criticos y nunca pueden omitirse. Si el
   usuario quiere omitir checks, pide una unica confirmacion para el conjunto completo,
   con una razon no vacia por check, y escribe exactamente
   `.angular-migration/runs/<run-id>/inbox/skips.json` con este contrato:

   ```json
   {
     "schemaVersion": 1,
     "runId": "<run-id>",
     "confirmed": true,
     "skips": [{ "checkId": "lint", "reason": "razon concreta" }]
   }
   ```

   Invoca una sola vez el controlador para el conjunto confirmado:

   ```powershell
    powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 skip-checks -RunId <run-id> -InputFile .angular-migration/runs/<run-id>/inbox/skips.json -Confirmed -ProjectRoot <ProjectRoot>
   ```

   Si no se solicita ninguna omision, continua directamente. No emitas varias
   confirmaciones ni uses `skip-checks` para gates criticos o checks de validacion
   final. La operacion batch es atomica: si una entrada falla, no se registra ninguna.

   Cuando `start` devuelva `status=running` y, si procede, `skip-checks` sea aceptado,
   comunica al usuario: "Todo esta listo para ejecutar la migracion. A partir de ahora
   trabajare autonomamente, sin pedir supervision en cada etapa. Solo me detendre si el
   controlador detecta un bloqueo, un fallo o necesita una reparacion tecnica acotada."
   No pidas otra confirmacion para cada stage.

4. Ejecuta `run` con el `runId` conservado como un unico proceso de fachada que pueda
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

   Si `run` termina en `blocked` con `error.code=baseline_check_failed` y el
   `checkId` actual es `typecheck`, `lint`, `unit-test` o `e2e`, presenta el diagnostico
   al usuario y explica que la omision es una excepcion auditada para este run. Indica
   siempre que `install`, `dependency-tree` y `build` son gates criticos y nunca pueden
   omitirse. Describe la razon concreta del fallo y pide confirmacion explicita para
   omitir unicamente el check identificado; una respuesta ambigua o negativa detiene
   el flujo.

   Tras la confirmacion, invoca exclusivamente la operacion del controlador:

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 skip-check -RunId <run-id> -CheckId <check-id> -Reason <reason> -Confirmed -ProjectRoot <ProjectRoot>
   ```

   `skip-check` acepta tanto una aprobacion durante `running/baseline` como el fallo
   baseline actual. Conserva la razon y el diagnostico en `state.json` y `events.jsonl`,
   y la conserva en el resultado tecnico cuando existe. Devuelve el mismo `runId` en
   `status=running`. No edites state ni ejecutes el check manualmente.
   Si la operacion es aceptada, vuelve a emitir el mensaje de trabajo autonomo y
   reanuda `run` con ese mismo `runId`. El check omitido aparece como `status=skipped`;
   los tres gates criticos siguen siendo obligatorios.

5. Para research, solo despues de observar `status.data.resolutionStatus=resolved`,
   ejecuta `documentation-context -Mode research`, entrega ese JSON al documenter y
   deja que escriba exclusivamente `allowedWritePath`. Lanza el documenter mientras
   continua el proceso original de `run`; la investigacion debe empezar antes de que
   el estado llegue a `verified`. Cuando el proceso de `run` termine en un estado
   estable y el agente haya entregado el JSON, registra su `research.json` con
   `record-documentation -Mode research`. El registro se hace desde el controlador,
   nunca desde el agente, para evitar escrituras concurrentes sobre `state.json`; no
   publica documentos finales.

6. Si el estado llega a `needs-repair`, ejecuta `repair-context` y lanza
   `migration-implementer` exactamente una vez para la pareja `fingerprint/attempt`.
   Rechaza cualquier intento de ampliar `allowedPaths` o modificar una ruta prohibida.
   Si `history.entryCount > 1`, el implementer debe leer `history.path` antes de editar,
   evitar combinaciones ya rechazadas o fallidas y justificar cualquier enfoque distinto
   con evidencia nueva. El implementer nunca escribe, trunca, renombra ni borra
   `repair.jsonl`.
   El implementer entrega `repair.json` y registra la reparacion mediante la fachada.
   No lances otro implementer para el mismo contexto.

   ```powershell
   powershell -NoProfile -File <plugin-root>\scripts\angular-migration.ps1 repair-context -RunId <run-id> -ProjectRoot <ProjectRoot>
   ```

7. Solo despues de que `record-repair` devuelva un envelope valido, reanuda `run` con
   el mismo `runId`. Nunca ejecutes manualmente un gate, ni aceptes `verified` desde el
   agente. `submission-accepted` solo confirma el commit controlado; espera a que el
   gate registre `verification-passed` antes de tratar la reparación como efectiva. Si
   aparece un nuevo fingerprint, tratalo como un nuevo intento controlado con su propio
   historial.

8. Cuando `migrationStatus=verified`, exige que research este registrado y emite
   `documentation-context -Mode publish`. Lanza `migration-documenter` en modo publish
   solo entonces. Publish y reparacion son secuenciales; no se solapan.

9. Tras la entrega del documenter, registra `documentation.json` con
   `record-documentation -Mode publish`. La fachada valida los ocho archivos, hashes,
   enlaces, claims y commits. La skill no ejecuta validaciones alternativas.

10. Consulta `status` una ultima vez y comunica unicamente el estado del artefacto:
    `completed`, `blocked` o `failed`. Solo `state.status=completed` permite declarar
    exito. Conserva `runId`, rutas de state/result y el diagnostico final.

## Reglas de agentes

- `migration-implementer` solo interviene en `needs-repair`, con el contexto emitido
  por `repair-context`, y una vez por `fingerprint/attempt`.
- `migration-documenter` usa research antes de verified y publish despues de verified.
- En publish, `migration-documenter` puede leer solo los `repair.jsonl` bajo
  `data.evidence.repairHistory` que correspondan a fingerprints accepted autorizados
  por el run; no puede editarlo, moverlo ni borrarlo.
- El documenter no ejecuta comandos ni cambia dependencias, configuracion, estado,
  manifest, resultado o logs.
- Si cualquiera de los agentes pide una ruta, herramienta o alcance no incluido en su
  contexto, no lo autorices: registra el bloqueo desde el envelope del controlador.
- Ningun agente instala dependencias baseline ni decide un skip. Esas acciones
  pertenecen exclusivamente a `approve-baseline-dependencies` y `skip-check`, despues
  de la confirmacion del usuario.
- Un agente no puede liberar el lock ni cambiar el estado final.

## Recuperacion

Ante una interrupcion, consulta `status` con el mismo `runId` y reanuda `run` solo si
el lock pertenece a un proceso que ya termino. Un run en `needs-repair` requiere una
entrega aceptada antes de reanudar. Si ya existe `submission-accepted` o
`verification-failed`, el controlador reconcilia history, informe archivado, HEAD,
state y events; nunca vuelve a ejecutar una mutacion a ciegas. Un JSONL corrupto o
evidencia ambigua bloquea el run. Un run bloqueado por un check baseline no critico
puede usar `skip-check` una vez con confirmacion explicita; un bloqueo por `install`,
`dependency-tree` o `build` no puede saltarse. Un run `verified` espera publish; un
run `completed` es terminal.
No crees un segundo run salvo para sustituir explicitamente ese baseline bloqueado.

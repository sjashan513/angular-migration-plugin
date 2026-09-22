# angular-migration v5

## 1. Proposito

Plugin para migrar exactamente una major de Angular por run. El controlador decide
versiones, orden, comandos, commits y transiciones; los agentes trabajan unicamente
con los contextos que el controlador les entrega.

## 2. Alcance soportado

- Windows.
- Windows PowerShell 5.1 o PowerShell 7+ para la fachada.
- PowerShell 7+ para los hooks de Copilot CLI.
- Proyectos Angular CLI en la raiz de un repositorio Git no monorepo.
- npm con `package-lock.json` v1, v2 o v3.
- Transiciones soportadas: Angular 7 -> 8, 8 -> 9 y 9 -> 10.
- Un salto `N -> N+1` por run; para llegar a una major posterior se ejecutan
  runs secuenciales dentro de esa matriz.
- Paquetes publicos resueltos desde `https://registry.npmjs.org/`; los paquetes
  `@ips/*` requieren una entrada `@ips:registry` HTTPS en `.npmrc` que coincida
  con la URL confiable `MIGRATION_IPS_REGISTRY`.

Quedan fuera de v5 la instalacion de Node sin aprobacion, Yarn, pnpm, workspaces, Nx,
dependencias no registry sin politica, agentes cloud y cualquier runtime visual.

## 3. Requisitos

Se necesita Windows, Git con identidad local, fnm, npm compatible con el lockfile y
GitHub Copilot CLI instalado y autenticado. El working tree debe estar limpio y
`.angular-migration/` debe estar ignorado por Git. El plugin selecciona runtimes
exactos con fnm y solo instala una version ausente despues de una aprobacion explicita.
La autenticacion del registry privado debe venir de la configuracion del usuario,
el runner o variables de entorno; nunca se aceptan credenciales embebidas en el
proyecto ni se usa fallback silencioso entre registries. La URL confiable del
registry privado debe configurarse fuera del repositorio mediante
`MIGRATION_IPS_REGISTRY`.

## 4. Instalacion

Desde el marketplace, instala el plugin `angular-migration` desde la entrada que
apunta al source del marketplace. Para una instalacion local, registra la carpeta
raiz de este repositorio como source de plugin en Copilot CLI y reinicia la sesion.
La comprobacion minima es que aparezcan la skill `angular-migration`, los dos agentes
definitivos y los hooks una sola vez.

## 5. Flujo

Ejecuta la fachada desde la raiz del proyecto o proporciona `-ProjectRoot`:

```powershell
./scripts/angular-migration.ps1 inspect -ProjectRoot C:\src\my-angular-app
./scripts/angular-migration.ps1 discover -TargetMajor 8 -ProjectRoot C:\src\my-angular-app
./scripts/angular-migration.ps1 approve-runtime-install -TargetMajor 8 -ProposalHash <proposal-hash> -Confirmed -ProjectRoot C:\src\my-angular-app
./scripts/angular-migration.ps1 start -TargetMajor 8 -ProjectRoot C:\src\my-angular-app
./scripts/angular-migration.ps1 skip-checks -ProjectRoot C:\src\my-angular-app -RunId <run-id> -InputFile .angular-migration/runs/<run-id>/inbox/skips.json -Confirmed
./scripts/angular-migration.ps1 run -ProjectRoot C:\src\my-angular-app -RunId <run-id>
./scripts/angular-migration.ps1 status -ProjectRoot C:\src\my-angular-app -RunId <run-id>
```

`preflight` e `inspect` son diagnósticos compatibles; el flujo operativo empieza con
`discover`, que persiste `.angular-migration/repo.json`, resuelve un plan de runtimes
por operación y detecta lockfile, npm y riesgos Webpack/OpenSSL. Si falta una versión
exacta, `approve-runtime-install` exige el hash de la propuesta y `-Confirmed`; no
ejecuta `fnm use` ni cambia el runtime predeterminado. `start` solo acepta un
discovery íntegro y listo, y la major objetivo debe ser exactamente la siguiente.
Antes de `run`, `skip-checks` permite aprobar en una sola operación las omisiones de
`typecheck`, `lint`, `unit-test` o `e2e`; el input se guarda en el run y la operación
es atómica. `run` reanuda desde el último checkpoint. `status` solo lee state y
diagnóstico. Cada comando escribe un único envelope JSON en stdout.

Si el baseline detecta peers npm ausentes, la skill ejecuta
`baseline-dependency-context`, explica las versiones exactas y los paquetes que las
requieren, y solicita confirmacion. Solo despues ejecuta
`approve-baseline-dependencies`, que instala esas versiones, valida `npm ls --all`,
crea un commit controlado y obliga a comenzar un run nuevo. La skill anuncia entonces
que la migracion esta lista para continuar autonomamente.

Si la baseline se bloquea por `lint`, `typecheck`, `unit-test` o `e2e`, la skill puede
pedir una aprobacion humana explicita para omitir solo ese check en el run actual:

```powershell
./scripts/angular-migration.ps1 skip-check -ProjectRoot C:\src\my-angular-app -RunId <run-id> -CheckId lint -Reason "Falta el tsconfig de lint del proyecto" -Confirmed
```

`skip-check` conserva esta recuperación individual para un único fallo baseline
posterior. `skip-checks` se usa antes de `run` para registrar el conjunto completo en
una sola escritura. Ambos conservan la razon y el diagnostico en `state.json`,
`events.jsonl` y el `result.json` tecnico cuando existe, y mantienen el mismo `runId`.
`install`, `dependency-tree` y `build` son gates criticos y nunca pueden omitirse.
Los checks aprobados aparecen como `skipped`; no se ejecutan gates manualmente fuera
de la fachada.

## 6. Agentes

`migration-implementer` interviene solo cuando el state esta en `needs-repair`. Recibe
un fingerprint, un attempt y un perimetro cerrado; no puede tocar `package.json`, el
lockfile, Git ni los artefactos del run.

Cada fingerprint conserva su propio historial append-only en
`.angular-migration/runs/<run-id>/repair-history/<fingerprint-sin-prefijo>/repair.jsonl`.
El implementer puede leer solo el historial activo y nunca puede escribirlo. Una
submission aceptada crea un commit, pero no es una reparacion efectiva hasta que el
gate posterior registra `verification-passed`; `verification-failed` conserva el
intento y entrega el siguiente contexto sin repetir la mutacion a ciegas.

`migration-documenter` tiene dos modos. Research empieza cuando el manifest esta
resuelto y puede ejecutarse en paralelo con la continuacion tecnica. Publish solo
empieza cuando `migrationStatus=verified` y produce exactamente ocho documentos. El
proceso principal registra las entregas mediante la fachada.

## 7. Controles

Los hooks y la fachada aplican allowlists de rutas y herramientas. El manifest
resuelto, el runtime, el resultado y las entregas se protegen con SHA-256. Los
eventos son append-only y cada etapa mutante deja un commit controlado. Las
aprobaciones de `skip-check` guardan check, razon, confirmacion, timestamp y
diagnostico original. No se
aceptan `--force`, `--legacy-peer-deps`, cambios sucios, comandos libres, push ni
decisiones de versionado provenientes de un agente. La reparacion baseline de peers es
una operacion del controlador y exige aprobacion humana con hash de propuesta.

## 8. Artefactos y retencion

Cada run vive en `.angular-migration/runs/<run-id>/` y contiene `manifest.json`,
`state.json`, `events.jsonl`, `result.json`, research, reparaciones, entregas, logs y
`repair-history/<fingerprint>/repair.jsonl`. El historial conserva contextos emitidos,
submissions recibidas o rechazadas, accepted y outcomes de verificacion hasta que el
run se archive; no se purga al pasar a `completed`, `blocked` o `failed`.
El lock activo esta en `.angular-migration/active.lock`. El plugin no purga artefactos
automaticamente: conserva el run para auditoria hasta que el responsable lo archive
segun la politica local. Los historiales son JSONL UTF-8 sin BOM, con hash individual
por entrada, y solo guardan rutas relativas, resumenes limitados y referencias a logs.
Se redactan rutas absolutas, URLs con credenciales, tokens, cabeceras, valores de
`.npmrc` y variables de entorno; no se guardan prompts, tool calls, diffs ni contenido
completo de archivos. Nunca se archiva `.npmrc`, el entorno ni tokens.

## 9. Recuperacion

Tras una interrupcion, usa `status` con el mismo `runId` y vuelve a ejecutar `run` una
vez confirmado que el proceso propietario del lock termino. Un run `needs-repair`
requiere `repair-context`, una entrega valida y `record-repair` antes de continuar.
Si el historial ya contiene `submission-accepted` o `verification-failed`, `run`
reconcilia el informe archivado, el commit, `state.json` y `events.jsonl`; no vuelve a
ejecutar una reparacion mutante solo porque falte una escritura de state. Si las
postcondiciones son ambiguas, el run falla cerrado con `repair_history_state_mismatch`.
Un historial vacio, truncado, con JSON invalido, secuencia discontinua o hash alterado
produce `repair_history_corrupt` y no se reconstruye automaticamente.
Un bloqueo baseline no critico puede continuar mediante `skip-check` con confirmacion;
los gates `install`, `dependency-tree` y `build` requieren resolver la causa. No
retires un lock de un proceso vivo ni crees otro run para reemplazar el primero.

## 10. Codigos de salida y errores

- `0`: operacion valida en `ready`, `running`, `verified` o `completed`.
- `2`: bloqueo reproducible o accion humana en `blocked` o `needs-repair`.
- `1`: fallo interno o estado `failed`.

Resuelve primero el `error.code` y el diagnostico de `status`; no relajes un gate con
opciones de bypass. Un bloqueo por peers npm puede seguir el contexto y aprobacion
baseline descritos arriba. Los bloqueos por Node, Git, lockfile, registry o scope
requieren corregir la precondicion y comenzar un run nuevo si el estado ya es terminal.
`result.json` solo presenta summaries de reparaciones accepted que tambien tienen
`verification-passed`; el documenter puede consultar historiales autorizados para
explicar intentos fallidos, pero la documentacion solo presenta como aplicada una
reparacion verificada.

## 11. Desinstalacion

Desinstala el plugin desde Copilot CLI y reinicia la sesion. La desinstalacion elimina
la skill, agentes y hooks del host del plugin, pero no modifica repositorios, ramas,
commits ni artefactos `.angular-migration` ya creados.

## 12. Limitaciones conocidas

No se instala Node fuera de una propuesta exacta aprobada por el controlador, no se
hace push, merge o pull request, no se reparan dependencias ni lockfiles desde un
agente y no se soportan proyectos fuera del perimetro npm/Git indicado. Solo se pueden
instalar runtimes y peers baseline propuestos por el controlador y aprobados
explicitamente. Un piloto real necesita una aplicacion Angular 7 descartable, fnm y un
entorno de Copilot CLI disponible.

## 13. Documentacion tecnica

El contrato de fases, estados, schemas, seguridad y fixtures esta en
[docs/README.md](docs/README.md).

MIT

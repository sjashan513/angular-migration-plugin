# Fase 9 — Discovery, runtimes Node y skips batch

## 1. Resultado de la fase

Al terminar esta fase, el plugin debe poder reconocer el repositorio antes de crear un
run, persistir una fotografía verificable en `.angular-migration/repo.json`, calcular
qué runtime de Node necesita cada operación y detectar si alguna versión falta en
`fnm`. La migración no puede comenzar hasta que exista un plan de runtimes completo y
reproducible.

La fase también sustituye la aprobación preflight de skips uno por uno por un comando
batch atómico. El usuario ve todos los checks opcionales en una única interacción y el
controlador registra el conjunto completo o no registra ninguno.

Resultados posibles de `discover`:

```text
ready                     El repositorio y todos sus runtimes están listos.
runtime-install-required  El plan es resoluble, pero faltan versiones exactas de Node.
blocked                   Hay una contradicción, metadata insuficiente o una precondición no soportada.
failed                    El controlador no pudo inspeccionar o persistir el discovery.
```

`runtime-install-required` se devuelve en el envelope como `status=blocked`, código de
salida `2` y `error.code=runtime_install_confirmation_required`. No crea run, rama,
commit, manifest ni lock de migración.

## 2. Decisiones no negociables

Esta fase reemplaza la limitación de v5 que obligaba al operador a seleccionar
manualmente una única versión de Node antes de ejecutar el plugin. A partir de esta
fase, el controlador puede usar versiones diferentes de Node según la operación y
puede instalar versiones ausentes exclusivamente después de una aprobación humana
explícita.

Se mantienen estas reglas:

1. `fnm` es el único gestor de versiones de Node soportado en esta fase.
2. El plugin no instala `fnm` ni modifica su configuración por defecto.
3. `discover` nunca instala Node, modifica el repositorio ni ejecuta gates.
4. Ninguna instalación ocurre sin una propuesta exacta, hash y `-Confirmed`.
5. No se acepta `latest`, `lts-latest`, `default`, rangos ni aliases como versión instalada.
6. No se ejecuta `fnm use`; cada proceso Node se lanza bajo un runtime explícito.
7. No se regenera ni degrada `package-lock.json` para adaptarlo a un npm antiguo.
8. `npm ci` conserva su comportamiento actual; no se añade una eliminación manual de `node_modules`.
9. No se añade `--force`, `--legacy-peer-deps`, `--ignore-scripts` ni otro bypass.
10. Git, PowerShell y los hooks no dependen del runtime Node del proyecto.

La selección de runtime es una decisión del controlador basada en evidencia. La skill,
el usuario y los agentes pueden aprobar una propuesta, pero no pueden proporcionar una
versión arbitraria para saltarse el plan.

## 3. Validación de la fase

Para considerar esta fase terminada deben pasar smoke, unitarios, integración y E2E.
En particular deben seguir funcionando:

- `preflight`, `inspect`, `discover`, `approve-runtime-install`, `start`, `run` y `status`;
- la resolución inmutable del manifest;
- los checks normalizados;
- los checkpoints y rollbacks;
- `skip-check` para recuperación de un único fallo baseline y `skip-checks` para la aprobación batch;
- la validación de rutas y ownership.

La evidencia debe incluir la selección exacta de Node, la aprobación explícita de
instalaciones, la incompatibilidad lockfile/npm, el riesgo Webpack/OpenSSL, la
integridad de `repo.json` y el movimiento atómico de `skips.json`. No se relajan otras
restricciones de v5.

## 4. Archivos permitidos

Crear:

```text
schemas/repo-discovery.schema.json
schemas/runtime-install-proposal.schema.json
schemas/skip-batch.schema.json
tests/unit/Discovery.Tests.ps1
tests/unit/RuntimePlanner.Tests.ps1
tests/integration/RuntimeSelection.Tests.ps1
tests/integration/SkipBatch.Tests.ps1
tests/fixtures/migrations/tools/fnm-fixture.ps1
tests/fixtures/tools/fnm-fixture.ps1
```

Modificar:

```text
scripts/angular-migration.ps1
scripts/modules/Migration.Core.psm1
scripts/modules/Migration.Project.psm1
scripts/modules/Migration.Dependencies.psm1
scripts/modules/Migration.Pipeline.psm1
scripts/modules/Migration.State.psm1
schemas/manifest.schema.json
schemas/state.schema.json
skills/angular-migration/SKILL.md
tests/smoke.ps1
tests/e2e/Invoke-Angular7To8.ps1
tests/unit/Baseline.Tests.ps1
tests/integration/BaselineCheckSkip.Tests.ps1
tests/integration/BaselineDependencyApproval.Tests.ps1
tests/integration/DependencyResolution.Tests.ps1
tests/integration/PipelineExecution.Tests.ps1
README.md
docs/README.md
docs/flujo-del-pipeline.md
```

No crear un sexto módulo PowerShell. `Project` descubre el repositorio, `Dependencies`
evalúa rangos publicados, `Core` ejecuta procesos y `Pipeline` construye y aplica el
plan. No añadir un agente de discovery ni delegar la selección de Node a un modelo.

## 5. API pública

La fachada añade estos comandos:

```powershell
./scripts/angular-migration.ps1 discover -TargetMajor <N> -ProjectRoot <root>
./scripts/angular-migration.ps1 approve-runtime-install -TargetMajor <N> -ProposalHash <hash> -Confirmed -ProjectRoot <root>
./scripts/angular-migration.ps1 skip-checks -RunId <run-id> -InputFile <path> -Confirmed -ProjectRoot <root>
```

`discover` es obligatorio antes de `start`. `TargetMajor` debe ser exactamente la
major actual más uno. `approve-runtime-install` solo instala las versiones exactas de
la propuesta vigente en `repo.json` y vuelve a ejecutar discovery. `skip-checks` opera
sobre un run ya creado que continúa en `running/baseline`.

`preflight` e `inspect` se conservan como comandos de diagnóstico compatibles, pero la
skill debe comenzar siempre por `discover`. Ninguno de los tres comandos antiguos
puede sustituir el plan de runtimes requerido por `start`.

La fachada añade parámetros cerrados:

```powershell
[string]$ProposalHash
[string]$InputFile
[switch]$Confirmed
```

No se acepta una versión Node, una ruta de ejecutable, un nombre de perfil, un rango o
argumentos de `fnm` desde la línea de comandos.

## 6. Alcance de discovery

`discover` reutiliza `Get-ProjectInspection`; no crea un segundo inventario divergente.
Amplía el resultado actual con información suficiente para responder antes de `start`:

- qué tipo de repositorio es y cuál es su proyecto Angular;
- versión Angular declarada y bloqueada;
- target secuencial solicitado;
- package manager y `lockfileVersion`;
- scripts de npm y checks configurados;
- configuraciones de TypeScript, lint, unit-test, build y e2e;
- dependencias directas y versiones bloqueadas de tooling relevante;
- declaraciones de Node del repositorio;
- restricciones Node de Angular origen y objetivo;
- requisitos npm derivados del lockfile;
- riesgos de runtime conocidos y demostrables;
- versiones exactas de Node instaladas en `fnm`;
- runtime seleccionado para cada operación;
- versiones exactas ausentes y propuesta de instalación.

Discovery no recorre `node_modules`, no analiza código fuente, no ejecuta `npm ci`, no
ejecuta scripts npm y no prueba el build. Su objetivo es detectar incompatibilidades
estáticas y de metadata antes de pagar el coste de los gates.

## 7. Fuentes de evidencia

El controlador procesa estas fuentes en orden de autoridad.

### 7.1 Declaraciones locales

Leer, cuando existan:

```text
.nvmrc
.node-version
.tool-versions
package.json#engines.node
package.json#engines.npm
package.json#packageManager
package.json#volta
package-lock.json#lockfileVersion
```

`.nvmrc` y `.node-version` solo admiten una versión exacta o un rango que el evaluador
soporte de forma inequívoca. En `.tool-versions` solo se procesa la entrada `nodejs`.
`volta.node` y `volta.npm` son evidencia declarada, pero Volta no se invoca ni modifica.

Si dos declaraciones locales son incompatibles, discovery devuelve:

```text
blocked / node_declarations_conflict
```

El diagnóstico enumera cada fuente y valor. No elige silenciosamente una de ellas.

### 7.2 Lockfile y npm

La versión del lockfile impone un mínimo de npm según una política versionada dentro de
`Migration.Project.psm1`:

```text
lockfileVersion 1  -> npm >= 5
lockfileVersion 2  -> npm >= 7
lockfileVersion 3  -> npm >= 7
```

La matriz es un mínimo de lectura, no una promesa de compatibilidad completa. Cuando
una versión Node ya está instalada, el controlador ejecuta bajo esa versión únicamente
`node --version` y `npm --version` para conocer el par real. No supone la versión npm
incluida por una major de Node.

Un lockfile v3 junto a Node 10/npm 6 debe producir un conflicto visible en
`repo.json`, no un fallo tardío de `npm ci`.

### 7.3 Angular origen y objetivo

Para Angular origen se utiliza la metadata bloqueada y publicada de `@angular/cli`,
`@angular/compiler-cli`, `@angular-devkit/*` y `@ngtools/*`. Para Angular objetivo se
consulta la misma metadata que usa el resolver de dependencias, sin publicar todavía
un manifest de run.

La consulta de target está limitada a la major secuencial solicitada y usa `npm view`
con argumentos estructurados. Si el registry no está disponible o no se puede obtener
`engines.node`, discovery bloquea con `runtime_metadata_unavailable`; no pospone la
decisión hasta `resolve`.

La metadata normalizada puede almacenarse dentro de `repo.json`, pero nunca se guarda
`.npmrc`, tokens, cabeceras o URLs con credenciales.

### 7.4 Tooling y riesgos conocidos

Inspeccionar las versiones bloqueadas de:

```text
webpack
@angular-devkit/build-angular
@angular/cli
typescript
karma
jest
cypress
```

No se crea una base genérica de compatibilidad de todo npm. Esta fase incorpora solo
reglas demostrables y versionadas. La primera regla obligatoria cubre Webpack y OpenSSL:

```text
webpack major <= 4 + Node major >= 17 -> riesgo webpack_openssl3_incompatible
```

Ante ese riesgo, el planner debe preferir un runtime Node 16 compatible con el resto de
restricciones. Solo considera mitigado el riesgo en Node 17+ si el script ya declara de
forma explícita `--openssl-legacy-provider`. El plugin no modifica scripts ni inyecta
`NODE_OPTIONS` automáticamente durante discovery.

Los patrones observados en CI pueden registrarse como hints, pero no son autoridad para
instalar o ejecutar una versión si contradicen engines, lockfile o metadata publicada.

## 8. Perfiles de runtime

No existe un único `projectNode`. El planner produce perfiles por operación:

```text
metadata             npm view y consultas de resolución
baseline-install     npm ci y npm ls anteriores a la migración
baseline-checks      typecheck, lint, unit-test, build y e2e por check
update-angular       CLI local y migrations de Angular
update-dependencies  renderer, npm install --package-lock-only
install              npm ci y npm ls posteriores a la migración
validate             typecheck, lint, unit-test, build y e2e por check
```

`baseline-checks` y `validate` no son un único runtime materializado. Cada check tiene
su propia entrada, porque build, tests y lint pueden imponer restricciones distintas.
Cuando una versión exacta satisface varios perfiles, el planner reutiliza esa versión
para reducir cambios de runtime.

Cada perfil contiene:

```json
{
  "id": "validate:build",
  "operations": ["build"],
  "requiredNodeRanges": [">=10.9.0", "<17"],
  "requiredNpmRange": ">=7",
  "constraints": [
    {
      "source": "package-lock.json#lockfileVersion",
      "value": "3",
      "reason": "npm must read lockfileVersion 3"
    },
    {
      "source": "package-lock.json#webpack",
      "value": "4.46.0",
      "reason": "Webpack 4 is incompatible with OpenSSL 3 by default"
    }
  ],
  "selectedNodeVersion": "16.20.2",
  "detectedNpmVersion": "8.19.4",
  "status": "installed"
}
```

Los rangos se evalúan con una única implementación compartida. Debe reutilizarse y,
si hace falta, ampliarse el evaluador existente de `Migration.Dependencies.psm1`.
Un rango publicado que el parser no entiende produce `unsupported_node_range`; no se
ignora y no se implementa otro parser parcial en `Project`.

## 9. Inventario y selección mediante fnm

Discovery exige `fnm` disponible y ejecutable. Conserva ruta y versión de `fnm`, pero
no confía en el Node activo de la terminal como inventario completo.

El controlador debe:

1. resolver `fnm.exe` o `fnm` una sola vez;
2. ejecutar la operación de listado soportada por la versión detectada;
3. normalizar únicamente versiones exactas `MAJOR.MINOR.PATCH`;
4. descartar aliases, prereleases y líneas no reconocidas;
5. verificar cada candidata instalada con un proceso estructurado equivalente a
   `fnm exec --using <exact> -- node --version`;
6. obtener su npm real con `fnm exec --using <exact> -- npm --version`;
7. marcar como no utilizable cualquier candidata cuya versión observada no coincida.

Si falta una candidata, se permite consultar el inventario remoto de `fnm` para formar
la propuesta. Esa consulta no instala nada. De las versiones que cumplen el perfil se
elige la última patch estable de la major LTS más alta que no active un riesgo conocido.
Si ya existe una versión instalada válida, tiene prioridad sobre una descarga nueva.

El objetivo secundario es minimizar el número de versiones distintas. No se sacrifica
una restricción para conseguirlo. Si dos perfiles no tienen intersección, se seleccionan
dos runtimes exactos.

Ejemplo esperado para el caso que motiva esta fase:

```text
Node 10.24.1 / npm 6.14.12  -> no puede leer lockfileVersion 3
Node 22.x / npm 10.x        -> instala, pero activa el riesgo Webpack 4/OpenSSL 3
Node 16.20.2 / npm 8.19.4   -> candidato para install y build si satisface engines
```

El ejemplo no convierte Node 16.20.2 en una constante global. La versión exacta debe
salir del plan calculado y de la evidencia disponible en cada repositorio.

## 10. Contrato de repo.json

La ruta es exactamente:

```text
<project>/.angular-migration/repo.json
```

El documento se valida contra `schemas/repo-discovery.schema.json`, se escribe
atómicamente y tiene `additionalProperties: false` en todos sus objetos contractuales.
Forma raíz mínima:

```json
{
  "schemaVersion": 1,
  "discoveryType": "angular-migration-repository",
  "projectRoot": "C:\\src\\app",
  "projectName": "legacy-app",
  "sourceMajor": 7,
  "targetMajor": 8,
  "status": "runtime-install-required",
  "discoveredAt": "2026-09-15T10:00:00.0000000Z",
  "inputFingerprint": "sha256:<64-hex>",
  "toolchain": {
    "fnm": {
      "available": true,
      "executable": "C:\\tools\\fnm.exe",
      "version": "1.38.1"
    },
    "installedNodeVersions": ["10.24.1", "22.20.0"]
  },
  "repository": {
    "angular": {
      "declaredCoreSpec": "^7.2.0",
      "resolvedCoreVersion": "7.2.16"
    },
    "packageManager": "npm",
    "lockfileVersion": 3,
    "scripts": {},
    "checks": [],
    "files": [],
    "dependencies": []
  },
  "runtimePlan": {
    "profiles": [],
    "conflicts": [],
    "missingVersions": ["16.20.2"]
  },
  "installProposal": {
    "versions": [
      {
        "version": "16.20.2",
        "profiles": ["baseline-install", "validate:build"],
        "reasons": [
          "npm must read lockfileVersion 3",
          "avoid Webpack 4/OpenSSL 3"
        ]
      }
    ],
    "proposalHash": "<64-hex>"
  },
  "warnings": [],
  "repoSha256": "<64-hex>"
}
```

`inputFingerprint` cubre, como mínimo, contenido y ruta relativa de:

```text
package.json
package-lock.json
angular.json
.nvmrc
.node-version
.tool-versions
configuraciones de checks detectadas
```

Los archivos ausentes se incluyen como ausencia explícita. El hash no incluye
`node_modules`, `.git`, `.angular-migration`, logs ni timestamps. `repoSha256` se
calcula sobre el documento canónico excluyendo el propio campo.

`start` debe releer las entradas, recalcular `inputFingerprint`, validar `repoSha256`,
comprobar `status=ready` y verificar que `targetMajor` coincide. Un snapshot stale
produce:

```text
blocked / discovery_stale
```

El manifest inicial copia el plan de runtimes y el hash de discovery. Después de
`start`, el run no consulta un `repo.json` mutable para decidir ejecutables.

## 11. Propuesta e instalación aprobada

Cuando faltan runtimes, `discover` devuelve la propuesta completa en `data` y persiste
el mismo objeto en `repo.json`. La propuesta contiene solo versiones exactas, perfiles,
razones y evidencia. `proposalHash` se calcula de forma canónica sin incluirse a sí
mismo.

La skill presenta en una sola interacción:

- cada versión exacta ausente;
- qué operaciones la necesitan;
- qué archivos o metadata originan la restricción;
- que la instalación modifica el inventario local de `fnm`, no el repositorio;
- que no se cambia la versión global o por defecto de Node.

`approve-runtime-install` exige:

1. `-Confirmed` presente;
2. `ProposalHash` con 64 hex minúsculas;
3. `repo.json` válido y `status=runtime-install-required`;
4. fingerprint de inputs sin cambios;
5. propuesta recalculada idéntica;
6. ausencia de un run activo;
7. ownership exclusivo de `.angular-migration/discovery.lock`.

Por cada versión ejecuta únicamente:

```text
fnm install <exact-version>
```

Los argumentos se pasan como array. No se aceptan flags proporcionados por el usuario.
Después verifica la versión real de Node y npm mediante `fnm exec --using`. Si una
instalación falla, no intenta desinstalar automáticamente versiones ya instaladas; el
envelope informa qué versiones quedaron disponibles y cuál falló. Nunca ejecuta
`fnm default`, `fnm use`, modifica el perfil de shell ni cambia variables persistentes.

Al terminar todas las instalaciones vuelve a ejecutar internamente el mismo discovery.
Solo devuelve `status=ready` si todos los perfiles quedan resueltos. La aprobación y
sus resultados se registran en `.angular-migration/runtime-install.jsonl`, no en un run
inexistente. Cada línea se redacta y contiene propuesta, versión, resultado, timestamp
y logs relativos; nunca entorno completo ni secretos.

## 12. Ejecución bajo un runtime explícito

Añadir en `Migration.Core.psm1` una única primitiva para procesos Node administrados.
Nombre recomendado:

```powershell
Invoke-MigrationNodeProcess
```

Debe recibir internamente una versión exacta autorizada, el ejecutable lógico y sus
argumentos estructurados. Construye una invocación equivalente a:

```text
fnm exec --using <exact-version> -- <executable> <arguments...>
```

La sintaxis exacta se verifica contra la versión mínima de `fnm` declarada por el
plugin y se cubre con fixtures. No se construye una línea shell, no se usa `cmd /c`, no
se cambia PATH global y no se llama a `fnm use`.

Deben migrarse a esta primitiva todas las operaciones que dependen de Node:

```text
node scripts/js/inspect-lockfile.js
node scripts/js/render-package-json.js
npm view
npm ci
npm ls --all
npm install --package-lock-only
npm run <check>
node_modules/.bin/ng.cmd update ...
```

Cada llamada obtiene su versión desde el plan inmutable del run. Antes del primer uso
de cada perfil se ejecutan `node --version` y `npm --version` bajo `fnm`; un mismatch
produce `runtime_identity_mismatch`. Si una versión desaparece durante el run, el
resultado es `blocked/runtime_missing`, nunca una selección automática distinta.

Las consultas de metadata anteriores a `start` usan el perfil `metadata` de
`repo.json`. Las posteriores usan la copia inmutable del manifest. No se permite usar
accidentalmente el Node activo de la terminal como fallback.

## 13. Conflictos de runtime

Discovery bloquea antes de `start` cuando:

- no existe versión estable que satisfaga un perfil;
- un rango Node publicado no es soportado por el evaluador;
- el npm observado no puede leer el lockfile;
- el runtime seleccionado activa un riesgo conocido sin mitigación explícita;
- la metadata origen y objetivo producen restricciones incompatibles para una misma operación;
- `fnm` falta o su versión no soporta la invocación cerrada;
- una versión remota necesaria no puede resolverse exactamente.

El diagnóstico contiene perfiles y restricciones, no una recomendación libre. Si dos
operaciones necesitan Node distintos, eso no es un conflicto: se crean dos perfiles.
Solo es conflicto cuando una única operación no tiene candidato.

## 14. skip-checks batch

La skill presenta todos los elementos configurados de
`repo.json.repository.checks` cuyo id sea:

```text
typecheck
lint
unit-test
e2e
```

El usuario responde una sola vez con el conjunto que desea omitir y una razón por
check. Después de `start`, la selección se escribe exclusivamente en:

```text
.angular-migration/runs/<run-id>/inbox/skips.json
```

Contrato:

```json
{
  "schemaVersion": 1,
  "runId": "angular-7-to-8-...",
  "confirmed": true,
  "skips": [
    {
      "checkId": "lint",
      "reason": "El repositorio no dispone de una configuración lint ejecutable"
    },
    {
      "checkId": "e2e",
      "reason": "El entorno E2E externo no está disponible para este run"
    }
  ]
}
```

`skip-checks` acepta `InputFile` solo si su ruta final coincide exactamente con la ruta
anterior. Rechaza reparse points, ADS, `..`, diferencias de casing y archivos fuera del
run. El schema es cerrado, exige entre uno y cuatro ids únicos y limita cada razón a
2000 caracteres.

La operación es atómica:

1. valida ownership y `running/baseline`;
2. valida el input completo;
3. comprueba que todos los checks están configurados en el manifest pendiente;
4. rechaza `install`, `dependency-tree`, `build` y cualquier id desconocido;
5. rechaza razones vacías o decisiones contradictorias ya registradas;
6. relee state y comprueba `stageRevision`;
7. añade todas las entradas a `skippedChecks` en una única escritura;
8. añade un único evento `skip-batch-accepted` con el conjunto auditado;
9. mueve el input a un artefacto inmutable del run;
10. devuelve `nextAction=run`.

Si una entrada falla, no se registra ninguna. `skip-check` individual se conserva para
la recuperación posterior de un único check baseline que ya haya fallado. No se usa el
comando batch para saltar checks de validación final.

La skill no debe pedir cuatro confirmaciones. Presenta la lista una vez, explica que
los gates críticos no son omisibles y solicita una única confirmación del conjunto.

## 15. Integración con start y run

El flujo obligatorio pasa a ser:

```text
discover -TargetMajor N
  -> si faltan runtimes: approve-runtime-install con confirmación
  -> discover queda ready
  -> confirmación de start
  -> start copia discovery y runtime plan al run
  -> una interacción batch de skips opcionales
  -> skip-checks si hay selección
  -> run usa runtimes por operación
```

`start` falla antes de crear el lock si discovery falta, está stale, tiene otro target o
contiene perfiles sin resolver. `run` nunca recalcula versiones Node. Un cambio de
`repo.json` después de start no cambia el plan del run.

Si el resolver de dependencias descubre una restricción Node objetivo que no estaba en
el snapshot, debe comparar esa evidencia con el plan copiado. Una contradicción produce
`blocked/runtime_plan_invalidated` antes de modificar `package.json`; no instala otra
versión en mitad del run. El operador vuelve a `discover` y comienza un run nuevo.

## 16. Seguridad y límites

La instalación de Node es una mutación del host y requiere los mismos principios de
aprobación que una reparación baseline:

- propuesta exacta y hasheada;
- confirmación explícita;
- ejecutable `fnm` resuelto por el controlador;
- argumentos cerrados;
- sin shell interpolation;
- sin privilegios elevados automáticos;
- sin modificación del runtime por defecto;
- sin descarga ejecutable fuera del mecanismo oficial de `fnm`;
- logs redactados;
- lock específico para impedir dos instalaciones concurrentes.

`repo.json` no guarda el entorno completo, PATH, HOME, tokens, `.npmrc` ni variables de
CI. Solo conserva rutas de ejecutables normalizadas, versiones y evidencia necesaria.

Los hooks deben permitir a la skill invocar únicamente los nuevos comandos y escribir
el input fijo de skips. Ningún agente puede ejecutar `fnm`, cambiar el runtime plan o
aprobar instalaciones.

## 17. Tests obligatorios

### 17.1 Discovery unitario

Cubrir:

- `.nvmrc`, `.node-version`, `.tool-versions`, engines y Volta;
- declaraciones coincidentes e incompatibles;
- lockfile v1, v2 y v3;
- npm 6 rechazado para lockfile v3;
- checks y configuraciones incluidos en `repo.json`;
- fingerprint estable y cambio ante inputs relevantes;
- ausencia de timestamps en el fingerprint;
- schema cerrado y hash canónico;
- snapshot stale rechazado por `start`;
- target no secuencial rechazado.

### 17.2 Planner de runtime

Cubrir:

- una versión satisface todos los perfiles;
- dos perfiles requieren versiones diferentes;
- runtime instalado tiene prioridad;
- falta runtime y se crea propuesta exacta;
- no se aceptan aliases ni prereleases;
- rango no soportado bloquea;
- `fnm` ausente bloquea;
- identidad Node/npm distinta a la esperada bloquea;
- Webpack 4 y Node 22 generan riesgo;
- Node 16 válido evita el riesgo OpenSSL 3;
- script con mitigación explícita se detecta sin modificarlo;
- planner minimiza versiones sin violar restricciones.

### 17.3 Instalación aprobada

Con un fixture `fnm` controlado:

- falta `-Confirmed`;
- proposal hash incorrecto;
- fingerprint stale;
- versión exacta instalada con argumentos estructurados;
- nunca se ejecuta `fnm use` o `fnm default`;
- fallo parcial se informa sin desinstalar versiones previas;
- discovery se repite después de instalar;
- instalación concurrente se bloquea;
- logs no contienen entorno ni secretos.

### 17.4 Ejecución por perfiles

Demostrar que:

- npm, node, ng y scripts pasan por `Invoke-MigrationNodeProcess`;
- Git y PowerShell no pasan por `fnm`;
- install usa el runtime del perfil install;
- build puede usar otro runtime;
- la versión activa de la terminal no altera el resultado;
- runtime ausente durante run bloquea sin fallback;
- reanudación conserva el mismo runtime plan;
- no se regenera el lockfile para cambiar su versión;
- `npm ci` continúa sin borrado manual adicional.

### 17.5 Skips batch

Cubrir:

- cero skips no requiere comando;
- uno y cuatro skips válidos;
- ids duplicados;
- check no configurado;
- gate crítico mezclado con opcionales;
- razón vacía o demasiado larga;
- ruta de input incorrecta o reparse point;
- confirmación ausente;
- conflicto de revisión;
- fallo de una entrada deja state sin cambios;
- escritura única contiene todo el conjunto;
- un único evento batch;
- `skip-check` individual sigue recuperando un fallo posterior.

### 17.6 E2E

Añadir un fixture que reproduzca el problema real:

```text
Angular legacy
declaración Node 10
package-lock.json lockfileVersion 3
Webpack 4
fnm con Node 10 y Node 22 instalados
Node 16 ausente
```

El E2E debe demostrar:

1. `discover` termina antes de ejecutar gates;
2. detecta npm 6 incompatible con lockfile v3;
3. detecta el riesgo Webpack 4/OpenSSL 3 con Node 22;
4. propone una versión exacta compatible;
5. no instala antes de confirmar;
6. la aprobación instala mediante `fnm`;
7. el segundo discovery queda `ready`;
8. install y build usan los perfiles seleccionados;
9. el run no falla veinte minutos después por una incompatibilidad ya detectable.

## 18. Orden de implementación

Implementar en este orden:

1. schemas y fixtures de discovery;
2. lectura de declaraciones y fingerprint;
3. inventario `fnm` y verificación Node/npm;
4. evaluador compartido de rangos;
5. planner por perfiles y regla Webpack/OpenSSL;
6. escritura y validación de `repo.json`;
7. comando `discover`;
8. propuesta e instalación aprobada;
9. primitiva `Invoke-MigrationNodeProcess`;
10. migración de todos los procesos Node al runtime explícito;
11. validación de discovery en `start`;
12. copia inmutable del plan al run;
13. schema y comando `skip-checks`;
14. actualización de skill y documentación;
15. unitarios, integración, smoke y E2E;
16. piloto contra el caso Node 10/lockfile v3/Webpack 4.

No implementar `skip-checks` antes de que `start` pueda confiar en un discovery válido.
No cambiar todos los invokes a `fnm` hasta disponer de tests de identidad y argumentos.

## 19. Checklist de salida

- [ ] `discover` es el primer paso obligatorio y no modifica el repo.
- [ ] `.angular-migration/repo.json` tiene schema, fingerprint y hash válidos.
- [ ] El snapshot incluye checks, lockfile, declaraciones y riesgos de runtime.
- [ ] El planner calcula runtimes por operación, no un Node global.
- [ ] Node 10/npm 6 con lockfile v3 se detecta antes de `start`.
- [ ] Webpack 4 con Node 17+ se detecta antes del build.
- [ ] Las versiones ausentes se proponen de forma exacta.
- [ ] Ninguna versión se instala sin hash y confirmación.
- [ ] Solo `fnm install <exact>` modifica el inventario local.
- [ ] No se ejecuta `fnm use`, `fnm default` ni se cambia PATH global.
- [ ] Todos los procesos Node usan el perfil inmutable mediante `fnm exec`.
- [ ] Git y PowerShell permanecen fuera del selector Node.
- [ ] `start` rechaza discovery ausente, stale o incompleto.
- [ ] `skip-checks` registra todo o nada con una sola confirmación.
- [ ] Los gates críticos continúan sin poder omitirse.
- [ ] `skip-check` individual sigue disponible para recuperación.
- [ ] `npm ci` conserva su limpieza nativa de `node_modules`.
- [ ] Smoke, unitarios, integración y E2E pasan en PowerShell 5.1 y PowerShell 7+.

# Fase 10 — Historial local de reparación

## 1. Resultado de la fase

Al terminar esta fase, cada fallo reparable debe disponer de un historial append-only
propio llamado `repair.jsonl`. Ese historial actúa como memoria L1 del implementer:
permite conocer qué se intentó para el fingerprint actual, por qué se rechazó o falló
y qué resultado produjo la reejecución del gate.

El historial no sustituye a `state.json`, `events.jsonl`, los informes aceptados ni los
logs técnicos. Su alcance es deliberadamente local: un run, un fingerprint y una cadena
de intentos sobre el mismo fallo. Un fingerprint nuevo empieza con un historial nuevo y
no recibe intentos de problemas no relacionados.

Resultados esperados:

```text
history-ready      El contexto de reparación incluye un historial válido y legible.
history-appended   El controlador añadió un hecho del intento de forma durable.
blocked            El límite de intentos se alcanzó o el historial requiere revisión.
failed             El historial fue alterado, se corrompió o no pudo persistirse.
```

## 2. Objetivo y límites

`repair.jsonl` existe para resolver dos problemas concretos:

1. evitar que el agente repita una reparación que ya fue intentada para el mismo fallo;
2. conservar una narración técnica compacta sin llenar el state o el event log global
   con submissions inválidas, hipótesis repetidas o intentos absurdos.

La autoridad sigue repartida así:

```text
state.json          Estado actual, ownership, etapa y contexto activo.
events.jsonl        Transiciones globales y hitos relevantes del run.
repair.jsonl        Memoria detallada del fingerprint y sus intentos.
repairs/*.json      Informes contractuales aceptados e inmutables.
logs/               stdout y stderr completos de gates y procesos.
```

`repair.jsonl` no autoriza una transición por sí solo. Solo `record-repair`, la
verificación del diff real y la posterior ejecución determinista del gate pueden mover
el run.

## 3. Precondiciones

Antes de implementar esta fase deben pasar todas las pruebas de las fases 3 a 9. Deben
estar operativos:

- `needs-repair` en `update-angular` y `validate`;
- fingerprint estable;
- `repair-context` y `record-repair`;
- rollback selectivo;
- límites de tres intentos por fingerprint y cinco reparaciones por run;
- runtime explícito por operación cuando la fase 9 esté implementada;
- hooks de lectura/escritura acotados.

El implementador debe capturar el comportamiento previo con los tests actuales. Esta
fase cambia dónde se conserva el detalle de intentos, pero no amplía rutas editables,
no aumenta límites y no permite que el agente controle el loop.

## 4. Archivos permitidos

Crear:

```text
schemas/repair-history-entry.schema.json
tests/unit/RepairHistory.Tests.ps1
tests/integration/RepairHistoryCycle.Tests.ps1
tests/fixtures/repair-history/
```

Modificar:

```text
scripts/modules/Migration.Pipeline.psm1
scripts/modules/Migration.State.psm1
scripts/hooks/copilot-policy.ps1
schemas/repair-context.schema.json
schemas/state.schema.json
agents/migration-implementer.agent.md
skills/angular-migration/SKILL.md
tests/integration/RepairCycle.Tests.ps1
tests/smoke.ps1
tests/e2e/Invoke-Angular7To8.ps1
README.md
docs/README.md
docs/flujo-del-pipeline.md
```

No crear un módulo PowerShell adicional. El historial forma parte del contrato de
reparación que ya pertenece a `Migration.Pipeline.psm1`. Las primitivas genéricas de
append durable pueden vivir en `Migration.Core.psm1` solo si se reutiliza la misma
implementación para `events.jsonl`; en caso contrario deben permanecer privadas en
Pipeline.

## 5. Ubicación y aislamiento

La ruta exacta se deriva del fingerprint, nunca de un nombre proporcionado por el
agente:

```text
.angular-migration/runs/<run-id>/repair-history/<fingerprint-hex>/repair.jsonl
```

`fingerprint-hex` son exclusivamente los 64 caracteres hexadecimales posteriores a
`sha256:`. No se conserva `:` en el nombre de carpeta porque Windows lo interpreta
como alternate data stream.

Ejemplo:

```text
.angular-migration/runs/angular-7-to-8-.../
  repair-history/
    9a31...f07c/
      repair.jsonl
```

La ruta debe resolverse dentro del run, rechazar reparse points, junctions, symlinks,
ADS, `..` y diferencias de casing. El implementer puede leer el archivo exacto del
fingerprint activo, pero nunca escribirlo. Solo el controlador abre el archivo en modo
append.

No existe un historial global por repositorio, por agente ni por proyecto. No se copia
el historial entre runs aunque el texto del error sea parecido. El checkpoint, manifest
y target forman parte del fingerprint y mantienen el aislamiento contextual.

## 6. Relación con state y events

`state.json` conserva únicamente información necesaria para gobernar el presente:

- contexto de reparación activo;
- fingerprint actual;
- siguiente attempt permitido;
- checkpoint y manifest esperados;
- resumen de reparaciones aceptadas;
- contador total necesario para el límite global.

No guarda root causes rechazadas, listas repetidas de cambios, claims del agente,
mensajes completos de validación ni todas las submissions recibidas.

`events.jsonl` conserva solo hitos de nivel run:

```text
repair-required
repair-accepted
repair-exhausted
```

No añade un evento global por cada JSON inválido, rechazo de schema, diff vacío,
repetición o hipótesis fallida. Esos detalles se escriben únicamente en el
`repair.jsonl` del fingerprint.

El evento `repair-accepted` continúa incluyendo fingerprint, attempt, commit y hash del
informe aceptado porque esos datos forman parte de la auditoría global. El detalle del
razonamiento y de los intentos permanece en el historial local.

## 7. Contrato de cada línea

Cada línea es un único objeto JSON comprimido UTF-8 sin BOM y termina con newline. Se
valida contra `schemas/repair-history-entry.schema.json`, que debe usar
`additionalProperties: false` en todos los objetos.

Forma raíz común:

```json
{
  "schemaVersion": 1,
  "sequence": 1,
  "entryId": "<32-hex>",
  "runId": "angular-7-to-8-...",
  "fingerprint": "sha256:<64-hex>",
  "attempt": 1,
  "type": "context-issued",
  "timestamp": "2026-09-15T10:00:00.0000000Z",
  "stage": "validate",
  "failedCheck": "build",
  "checkpointCommit": "<40-hex>",
  "manifestSha256": "<64-hex>",
  "data": {},
  "entrySha256": "<64-hex>"
}
```

`sequence` comienza en uno y aumenta exactamente en uno. `entryId` se genera por el
controlador. `entrySha256` es SHA-256 del objeto canónico excluyendo ese campo. La
secuencia, identidad del run, fingerprint, checkpoint, manifest y hash se verifican al
leer el archivo completo.

No se implementa una cadena de hashes entre entradas. El hash individual detecta una
línea alterada y la secuencia detecta inserciones o eliminaciones accidentales. La
protección principal sigue siendo la allowlist del hook y la escritura exclusiva del
controlador.

## 8. Tipos de entrada

Los únicos tipos permitidos son:

```text
context-issued
submission-received
submission-rejected
submission-accepted
verification-failed
verification-passed
attempts-exhausted
```

### 8.1 context-issued

Se añade cuando el controlador crea por primera vez un contexto para ese attempt. No
se repite al consultar `repair-context` otra vez.

```json
{
  "allowedPaths": ["src/**/*"],
  "diagnosticSummary": "TypeScript compilation failed",
  "logFiles": [
    ".angular-migration/runs/<run-id>/logs/validate/06-build.stderr.log"
  ]
}
```

No incluye el contenido de los logs ni el inventario completo de archivos protegidos.

### 8.2 submission-received

Se añade después de resolver la ruta fija y leer un JSON válido, antes de validar su
contenido contra el contexto.

```json
{
  "submissionSha256": "<64-hex>",
  "declaredRootCause": "La API observada cambió de firma",
  "declaredChanges": [
    {
      "path": "src/app/example.component.ts",
      "summary": "Adapta la llamada a la firma soportada"
    }
  ]
}
```

Si el input no es JSON válido o no puede leerse con seguridad, no se guarda su contenido
ni un hash de bytes potencialmente secretos. Se escribe directamente
`submission-rejected` con un código genérico y redactado.

### 8.3 submission-rejected

Registra por qué el controlador rechazó el intento y si el rollback selectivo pasó.

```json
{
  "code": "repair_diff_mismatch",
  "message": "El diff real no coincide con changes[]",
  "changedPaths": ["src/app/example.component.ts"],
  "scopeViolation": false,
  "rollbackStatus": "passed"
}
```

No almacena raw JSON, contenido de archivos, stdout completo, variables de entorno o
stack traces. Los códigos son una allowlist versionada, no mensajes arbitrarios del
agente.

### 8.4 submission-accepted

Registra el informe archivado y el checkpoint creado:

```json
{
  "report": ".angular-migration/runs/<run-id>/repairs/<hash>-attempt-1.json",
  "reportSha256": "<64-hex>",
  "commit": "<40-hex>",
  "changedPaths": ["src/app/example.component.ts"]
}
```

### 8.5 verification-failed

Se añade cuando el controlador reejecuta el gate después de una reparación aceptada y
el fallo persiste.

```json
{
  "checkId": "build",
  "exitCode": 1,
  "timedOut": false,
  "diagnosticSummary": "El build sigue fallando con TS2554",
  "logFiles": [
    ".angular-migration/runs/<run-id>/logs/validate/06-build.stderr.log"
  ],
  "nextAttempt": 2,
  "sameFingerprint": true
}
```

Si la reejecución genera otro fingerprint, la entrada final del historial anterior usa
`sameFingerprint=false` y referencia únicamente el nuevo fingerprint. El detalle del
nuevo fallo comienza en su propio `repair.jsonl`.

### 8.6 verification-passed

Registra que el gate determinista validó la reparación:

```json
{
  "checkId": "build",
  "exitCode": 0,
  "timedOut": false,
  "resultLogFiles": [],
  "verifiedCommit": "<40-hex>"
}
```

El agente nunca escribe esta entrada ni afirma este resultado.

### 8.7 attempts-exhausted

Se añade exactamente una vez cuando se alcanza el tercer intento del fingerprint o el
límite global de cinco reparaciones del run. Contiene el límite alcanzado y la siguiente
acción humana, sin copiar todas las entradas anteriores.

## 9. Escritura append-only

Añadir funciones privadas equivalentes a:

```powershell
Get-RepairHistoryPath
Read-RepairHistory
Add-RepairHistoryEntry
Get-RepairAttemptSummary
```

`Add-RepairHistoryEntry` debe:

1. derivar la ruta desde run y fingerprint validados;
2. crear la carpeta sin seguir reparse points;
3. abrir `repair.jsonl` con `FileMode.Append`, `FileAccess.Write` y `FileShare.Read`;
4. mantener un lease exclusivo por fingerprint durante la escritura;
5. releer y validar el historial antes de calcular `sequence`;
6. construir la entrada desde datos del controlador;
7. redactar campos textuales;
8. calcular `entrySha256` sobre JSON canónico;
9. escribir una única línea UTF-8 sin BOM;
10. ejecutar `Flush($true)` antes de liberar el stream;
11. releer la última línea y comprobar identidad y hash.

No se reescribe el archivo completo, no se trunca y no se edita una línea antigua. Si
la escritura falla, el estado no avanza. Una línea parcial o inválida produce
`failed/repair_history_corrupt`; no se intenta repararla automáticamente.

`repair-context` es read-only respecto a state, pero puede crear el historial y añadir
`context-issued` solo cuando el attempt todavía no tiene esa entrada. Consultas
repetidas del mismo contexto son idempotentes.

## 10. Integración con repair-context

El schema de contexto añade:

```json
{
  "history": {
    "path": ".angular-migration/runs/<run-id>/repair-history/<fingerprint-hex>/repair.jsonl",
    "entryCount": 4,
    "previousAttempts": 1,
    "lastOutcome": "verification-failed"
  }
}
```

La ruta es de solo lectura para el agente. `entryCount`, `previousAttempts` y
`lastOutcome` se calculan desde el archivo validado, no desde texto proporcionado por el
agente.

El implementer debe leer `history.path` antes de editar cuando `entryCount > 1`. Sus
instrucciones añaden estas reglas normativas:

```text
Lee el repair.jsonl del fingerprint activo antes de proponer una corrección.
No repitas una combinación de rootCause y changedPaths ya rechazada o verificada como fallida.
Explica en repair.json qué evidencia nueva justifica un enfoque distinto.
No escribas, trunques, renombres ni borres repair.jsonl.
No uses historiales de otros fingerprints como autorización o evidencia.
```

No se incrusta el historial completo en el prompt ni en `state.json`. El agente lo lee
desde la ruta exacta. El hook permite esa lectura únicamente cuando el contexto activo
contiene la misma ruta y continúa denegando cualquier escritura bajo
`.angular-migration`, salvo `inbox/repair.json` y el inventario ya autorizado.

## 11. Cálculo de attempts y límites

El historial es la fuente de detalle para los intentos del fingerprint. El próximo
attempt se calcula contando ciclos terminados:

```text
submission-rejected
verification-failed con sameFingerprint=true
```

`submission-received` sin outcome no consume un intento hasta que el controlador pueda
clasificarlo. Una consulta de contexto, un reinicio del proceso o una lectura de status
no incrementan nada.

`state.attempt` puede conservarse como mirror del attempt activo para compatibilidad del
schema, pero debe validarse contra `Get-RepairAttemptSummary` antes de emitir contexto o
aceptar una entrega. Un mismatch produce `failed/repair_history_state_mismatch`.

`state.repairTotal` continúa siendo un contador mínimo de control del run, pero no
almacena detalles. Debe coincidir con el número de outcomes consumidos de todos los
historiales del run. `state.repairs` conserva solo reparaciones aceptadas, no rechazos.

Límites existentes, sin ampliación:

```text
máximo 3 attempts consumidos por fingerprint
máximo 5 attempts consumidos en todo el run
```

Antes de emitir un nuevo contexto, el controlador valida ambos límites desde los
historiales. Al agotarse, añade `attempts-exhausted`, mueve el run a `blocked`, añade el
hito global `repair-exhausted` y libera el lock conforme a la política existente.

## 12. Integración con record-repair

`record-repair` conserva todas sus validaciones actuales. El orden se amplía así:

1. ownership y lease de `record-repair`;
2. validación completa del historial activo;
3. run, stage, fingerprint y attempt contra history y state;
4. ruta fija de submission;
5. lectura segura del input;
6. append `submission-received` si el JSON es apto para resumen;
7. schema, manifest, HEAD, diff, paths, modos, hashes y runtime;
8. ante rechazo, rollback selectivo;
9. append `submission-rejected` con código cerrado;
10. ante aceptación, archivar informe y crear commit;
11. append `submission-accepted`;
12. actualizar state mínimo;
13. añadir `repair-accepted` al event log global;
14. volver a `running` en la misma etapa.

Una submission evidentemente inválida no debe añadir varias entradas repetidas si sus
bytes, fingerprint y attempt son idénticos. El controlador mantiene idempotencia por
`submissionSha256` cuando puede calcularlo de forma segura. Una repetición exacta
devuelve el outcome anterior sin consumir otro attempt.

Las violaciones de scope y fallos de rollback continúan llevando el run a `failed`.
Aunque sean terminales, primero se intenta persistir el outcome redactado en el
historial. Si no se puede persistir, prevalece `repair_history_write_failed` y el run no
continúa.

## 13. Integración con la reejecución del gate

Cuando una reparación aceptada devuelve el run a `running`, Pipeline conserva el
fingerprint y attempt pendientes de verificación hasta que se ejecute exactamente el
gate fallido.

Si el gate pasa:

1. añadir `verification-passed`;
2. cerrar el contexto activo de state;
3. continuar con los siguientes gates;
4. no volver a invocar al implementer para ese fingerprint.

Si el gate falla:

1. recalcular el fingerprint con el algoritmo vigente;
2. añadir `verification-failed` al historial anterior;
3. si coincide, calcular el siguiente attempt desde ese historial;
4. si cambia, cerrar el anterior y crear el historial del nuevo fingerprint;
5. comprobar límites antes de emitir otro contexto;
6. volver a `needs-repair` solo si existe scope seguro.

Una reparación aceptada no se considera exitosa por tener commit. Solo
`verification-passed` demuestra que el gate validó el cambio.

## 14. Resumen que recibe el agente

El historial debe ser útil sin obligar al agente a reconstruir el run completo. Cada
`repair-context` conserva el diagnóstico actual y añade la ruta de history. El agente
puede responder estas preguntas leyendo únicamente ese archivo y los logs referenciados:

- qué root causes ya propuso;
- qué rutas modificó en cada intento;
- qué submissions fueron rechazadas por contrato;
- qué reparaciones fueron aceptadas pero no arreglaron el gate;
- qué códigos y mensajes permanecieron después de verificar;
- qué attempt está activo y cuántos quedan.

No se guardan deliberaciones internas, conversaciones completas, prompts, tool calls,
diffs completos ni contenido fuente. La memoria describe resultados y evidencia, no el
razonamiento privado del modelo.

## 15. Redacción y datos sensibles

Todos los textos pasan por `Protect-RepairText` antes de persistirse. Además:

- las rutas absolutas del proyecto se convierten a relativas;
- URLs con credenciales se eliminan;
- tokens, cabeceras y valores `.npmrc` se redactan;
- variables de entorno no se copian;
- stdout/stderr se referencian mediante rutas, no se incrustan;
- el contenido de archivos modificados no se guarda;
- mensajes arbitrarios se limitan en longitud;
- `changedPaths` se deriva de Git o del informe validado según el tipo de entrada.

Si la redacción altera una submission aceptable, el informe contractual original no se
reescribe. El historial recibe el resumen redactado y el informe archivado conserva las
reglas de seguridad ya existentes. Un secreto detectado en la submission continúa
provocando rechazo.

## 16. Corrupción y recuperación

Al leer un historial, validar:

1. UTF-8 y una entrada JSON por línea;
2. schema cerrado;
3. `sequence` continuo desde uno;
4. `entryId` único;
5. run, fingerprint, stage y failedCheck consistentes;
6. attempts monótonos y dentro del límite;
7. orden lógico de tipos;
8. hashes individuales;
9. referencias contenidas dentro del run;
10. ausencia de entradas después de un outcome terminal incompatible.

Un archivo inexistente es válido únicamente antes del primer `context-issued`. Un
archivo vacío, truncado, con una última línea parcial o con hash incorrecto produce:

```text
failed / repair_history_corrupt
```

No se ignora la última línea, no se elimina y no se reconstruye automáticamente desde
events. El diagnóstico informa la ruta y sequence afectada sin incluir contenido
sensible. La recuperación requiere restaurar el artefacto desde evidencia del run o
cerrar el run manualmente según la política local.

Ante una interrupción después de append pero antes de actualizar state, la reanudación
reconcilia el historial con Git, informe archivado y eventos globales. Si las
postcondiciones demuestran que la acción terminó, completa el state sin duplicar la
entrada. Si son ambiguas, bloquea; nunca vuelve a ejecutar una reparación mutante a
ciegas.

## 17. Retención y documentación final

Los historiales se conservan junto al run hasta que este se archive. No se purgan al
pasar a `completed`, `blocked` o `failed`.

`result.json` incluye únicamente reparaciones accepted que también tienen una entrada
`verification-passed` del mismo fingerprint y attempt. No incorpora todos los intentos
rechazados ni hashes de cada línea. El documenter puede leer
`repair.jsonl` para explicar intentos relevantes, pero la documentación final solo
presenta como reparación aplicada aquella que tenga `submission-accepted` y
`verification-passed`.

Una submission absurda o inválida no debe aparecer en documentación de producto salvo
que explique un bloqueo terminal. Así se mantiene separada la memoria operativa del
agente de la evidencia técnica que consume el equipo.

## 18. Seguridad del hook

Actualizar `copilot-policy.ps1` para el implementer:

```text
read  permitido solo sobre el repair.jsonl exacto del contexto activo
edit  denegado sobre repair-history/**
write denegado sobre repair-history/**
move  denegado sobre repair-history/**
delete denegado sobre repair-history/**
```

El controlador sigue pudiendo escribir mediante sus funciones internas; la allowlist
del hook no sustituye a las validaciones de Pipeline.

Un timeout o ausencia del hook no permite alterar el historial: antes de emitir contexto
y antes de `record-repair`, Pipeline verifica ruta, secuencia, schema y hashes. Si el
agente consigue modificar el archivo por otro medio, el run falla cerrado.

## 19. Tests obligatorios

### 19.1 Unitarios de historial

Cubrir:

- ruta derivada desde fingerprint sin `sha256:`;
- aislamiento entre runs y fingerprints;
- primer sequence igual a uno;
- incremento exacto;
- JSONL UTF-8 sin BOM;
- append que no reescribe líneas anteriores;
- schema cerrado por tipo;
- hash canónico válido;
- entryId duplicado rechazado;
- sequence ausente o duplicado rechazado;
- línea parcial y JSON inválido;
- hash alterado;
- ruta con reparse point o ADS;
- redacción de secretos y rutas absolutas;
- límites de longitud.

### 19.2 Máquina de intentos

Cubrir:

- consultar contexto no consume attempt;
- submission rechazada consume uno;
- submission repetida idéntica es idempotente;
- accepted sin verificación no cierra el intento;
- verification failed consume el ciclo;
- verification passed lo cierra con éxito;
- mismo fingerprint incrementa attempt;
- fingerprint nuevo crea otro historial;
- cuarto intento se bloquea;
- sexto intento global se bloquea;
- state mirror distinto del historial falla cerrado.

### 19.3 Integración record-repair

Cubrir:

- contexto crea `context-issued` una vez;
- submission válida añade received y accepted;
- diff mismatch añade rejected y hace rollback;
- scope violation añade outcome redactado y termina failed;
- JSON ilegible no persiste raw bytes;
- informe aceptado conserva su artefacto actual;
- events globales no reciben cada rechazo;
- state no acumula root causes o claims rechazados;
- fallo de append impide commit o transición;
- concurrencia del mismo fingerprint se serializa.

### 19.4 Reejecución

Cubrir `update-angular` y `validate`:

- gate posterior pasa y añade verification-passed;
- gate posterior falla con mismo fingerprint;
- gate posterior falla con fingerprint distinto;
- checks posteriores no se ejecutan antes de cerrar verificación;
- reanudación no duplica outcome;
- commit aceptado sin gate verde no se documenta como éxito.

### 19.5 Hook

Cubrir:

- implementer lee solo el history activo;
- otro fingerprint se deniega;
- edición, rename y delete se deniegan;
- inbox/repair.json continúa permitido;
- documenter solo lee history cuando el contexto publish lo autoriza;
- Pipeline detecta manipulación aunque el hook no se ejecute.

### 19.6 E2E

El E2E determinista debe producir:

```text
attempt 1: repair aceptado, gate vuelve a fallar
attempt 2: repair aceptado, gate pasa
```

Después comprueba:

- un único `repair.jsonl` para el fingerprint;
- sequence continuo;
- el segundo contexto contiene history con el resultado anterior;
- el segundo agente no recibe historiales ajenos;
- state solo conserva el contexto actual y accepted summaries;
- events contiene hitos globales, no cada detalle;
- result incluye la reparación verificada;
- documentación final distingue intento fallido y reparación efectiva.

## 20. Orden de implementación

Implementar en este orden:

1. schema cerrado por tipos de entrada;
2. path derivado y validación Windows;
3. lectura completa y validación de secuencia/hash;
4. append durable e idempotencia;
5. `context-issued` y ampliación de repair-context;
6. permisos read-only del hook;
7. integración received/rejected/accepted en record-repair;
8. cálculo de attempts desde history;
9. reconciliación mínima con state;
10. integración verification failed/passed en ambos stages;
11. límites y outcome exhausted;
12. reducción de detalle duplicado en events y state;
13. instrucciones del implementer;
14. soporte documental de accepted + verified;
15. unitarios, integración, smoke y E2E;
16. prueba de interrupción entre append, commit y transición.

No eliminar campos existentes de state antes de disponer de reconciliación y tests de
compatibilidad. Primero convertirlos en mirrors validados; una futura versión de schema
puede retirarlos en una fase separada.

## 21. Checklist de salida

- [ ] Cada fingerprint tiene su propio `repair.jsonl` dentro del run.
- [ ] El nombre de carpeta es Windows-safe y deriva del fingerprint validado.
- [ ] Solo Pipeline puede añadir entradas.
- [ ] El implementer puede leer únicamente el historial activo.
- [ ] Cada línea tiene schema cerrado, sequence, identidad y hash válidos.
- [ ] Consultar context o status no consume attempts.
- [ ] Submissions repetidas son idempotentes.
- [ ] El agente ve root causes, paths y outcomes previos del mismo fallo.
- [ ] State no acumula narrativas de intentos rechazados.
- [ ] Events no recibe un registro por cada intento absurdo.
- [ ] Los límites se calculan y validan contra history.
- [ ] Una reparación aceptada no se considera exitosa hasta verificar el gate.
- [ ] Un fingerprint nuevo empieza con memoria vacía.
- [ ] Corrupción o manipulación falla cerrado.
- [ ] Raw prompts, tool calls, diffs, secretos y logs completos no se persisten.
- [ ] Result y documentación final distinguen accepted de verified.
- [ ] Unitarios, integración, hook, smoke y E2E pasan en PowerShell 5.1 y 7+.

# Retrospectiva y propuestas de mejora para Angular Migration

## 1. Objetivo

Este documento recoge los problemas observados al utilizar Angular Migration para
migrar este repositorio de Angular 9 a Angular 10.

El propósito es mejorar:

- el diagnóstico previo;
- la resolución de dependencias;
- las autorizaciones del usuario;
- la recuperación después de un fallo;
- la observabilidad de procesos largos;
- la compatibilidad entre runtimes y tooling;
- los contratos de seguridad del plugin.

El documento distingue entre:

- **Problema observado:** comportamiento reproducido durante esta migración.
- **Impacto:** efecto sobre el usuario o el run.
- **Propuesta:** cambio recomendado para el plugin.

## 2. Resumen ejecutivo

El plugin dispone de mecanismos valiosos de seguridad:

- máquina de estados;
- locks de ejecución;
- manifests con hash;
- checkpoints de Git;
- commits controlados;
- confirmaciones explícitas;
- rollback de cambios parciales;
- separación entre checks opcionales y gates críticos.

Sin embargo, la experiencia actual presenta tres problemas estructurales.

### 2.1. Descubrimiento incremental de errores

El resolver y algunas etapas terminan ante el primer problema. Esto obliga a repetir
operaciones costosas para descubrir el siguiente bloqueo.

### 2.2. Recuperación demasiado específica

La recuperación depende de casos implementados individualmente. Una etapa puede ser
técnicamente reintentable, pero el controlador no siempre ofrece una transición segura.

### 2.3. Seguridad que puede bloquear la recuperación

El hook de autorización puede impedir las operaciones necesarias para diagnosticar,
reparar, cancelar o finalizar un run.

La prioridad principal debe ser garantizar que ningún run pueda quedar en un estado
autorizado por la máquina de estados, pero imposible de recuperar mediante la fachada
pública.

## 3. Problemas observados

### 3.1. El resolver informa un único conflicto por ejecución

#### Problema observado

La resolución se detenía ante el primer conflicto. Fue necesario ejecutar varios
ciclos para descubrir problemas diferentes:

- versiones deprecated;
- selector incorrecto de Angular DevKit;
- rangos semver no soportados correctamente;
- incompatibilidades peer de `@ips/ionic`;
- ausencia de `tslib` como dependencia directa;
- ausencia de `core-js` como dependencia directa.

Un diagnóstico externo y no mutante demostró que todos estos problemas podían
descubrirse en una única pasada.

#### Impacto

- Feedback muy lento.
- Consultas repetidas al registry.
- Reapertura manual de la misma etapa.
- Dificultad para estimar el alcance real de la migración.

#### Propuesta

Añadir un modo de diagnóstico exhaustivo y read-only, por ejemplo
`resolve-diagnostics`, que:

- recorra todo el inventario;
- acumule errores y warnings;
- no modifique el proyecto ni el run;
- agrupe problemas por causa;
- identifique decisiones que requieren autorización;
- genere un artefacto reproducible con hash.

La resolución real debería reutilizar este artefacto mientras el lockfile,
`package.json` y la metadata relevante no hayan cambiado.

### 3.2. La recuperación está limitada a etapas concretas

#### Problema observado

Un run bloqueado en `resolve` no podía continuar originalmente. Se añadió
`retry-stage`, pero inicialmente solo contemplaba esa etapa.

Posteriormente, `update-angular` falló sin dejar cambios persistentes y también
necesitó un mecanismo de reintento.

#### Impacto

- Repetición innecesaria de la pipeline.
- Tentación de editar `state.json` manualmente.
- Necesidad de añadir excepciones una por una al controlador.
- Ciclos largos para probar cambios pequeños del plugin.

#### Propuesta

Cada etapa debe declarar una política de recuperación:

| Etapa                 | Reintento seguro                        |
| --------------------- | --------------------------------------- |
| `inspect`             | Siempre, porque es read-only            |
| `discover`            | Siempre, porque es read-only            |
| `baseline`            | Si no existe una operación activa       |
| `resolve`             | Si el manifest sigue pendiente          |
| `update-angular`      | Después de rollback verificado          |
| `update-dependencies` | Desde el último checkpoint válido       |
| `install`             | Si el manifest no ha cambiado           |
| `validate`            | Sin repetir etapas mutantes             |
| `publish`             | Si no existe una publicación confirmada |

La política debe definir:

- precondiciones;
- operaciones completadas esperadas;
- checkpoint requerido;
- hashes requeridos;
- archivos que pueden haber cambiado;
- verificación del rollback;
- transición de estado permitida.

`retry-stage` debería consumir esta política común en lugar de implementar casos
aislados.

### 3.3. Las confirmaciones están demasiado fragmentadas

#### Problema observado

Los fallos preexistentes de `lint`, `unit-test` y `e2e` se confirmaron por separado.
También surgieron decisiones relacionadas con peers internos, promoción de
dependencias transitivas, paquetes deprecated y uso de flags especiales.

#### Impacto

- Demasiadas interrupciones.
- Pérdida de contexto entre confirmaciones.
- Feedback especialmente lento al probar el plugin.
- Riesgo de aprobar acciones sin ver su impacto conjunto.

#### Propuesta

Agrupar decisiones relacionadas en una propuesta única:

```text
La baseline contiene tres fallos preexistentes:

- lint: falta src/tsconfig.app.json
- unit-test: falta src/tsconfig.spec.json
- e2e: Webpack 4 no funciona con el runtime seleccionado

Se propone omitir estos tres checks opcionales para este run.
Los gates install, dependency-tree y build seguirán siendo obligatorios.
```

La propuesta debe incluir:

- acciones exactas;
- razón por acción;
- riesgo;
- alcance;
- hash;
- fecha de generación;
- fingerprint de los archivos relevantes.

Una autorización solo debe ser válida para ese hash.

### 3.4. No existe una política formal para paquetes internos

#### Problema observado

`@ips/ionic@0.4.0` publica peers compatibles con Angular 9, pero no con Angular 10.
El equipo autorizó ignorar esa incompatibilidad porque se trata de un paquete
interno. Ignorar todos sus peers habría omitido también requisitos válidos como
RxJS o `tslib`.

#### Propuesta

Introducir excepciones declarativas, limitadas y auditables:

```json
{
  "package": "@ips/ionic",
  "version": "0.4.0",
  "ignoredPeers": [
    "@angular/core",
    "@angular/common",
    "@angular/router",
    "@ionic/angular"
  ],
  "reason": "Paquete interno cuya compatibilidad será validada por el equipo",
  "scope": "run"
}
```

El plugin debe validar todos los peers no incluidos, registrar un warning, conservar
la autorización y evitar reglas hardcoded para paquetes concretos.

### 3.5. Los peers transitivos compatibles se consideran ausentes

#### Problema observado

Las versiones necesarias de `tslib` y `core-js` ya estaban presentes en el lockfile
y cumplían los rangos requeridos, pero no estaban declaradas directamente en
`package.json`.

#### Propuesta

Cuando un peer obligatorio:

- existe en el lockfile;
- satisface el rango;
- no cambia paquetes Angular;
- puede asignarse a una sección inequívoca;

el resolver debe generar una propuesta `promote-transitive-peer`. Todas las
promociones compatibles deben presentarse en un único lote. El plugin no debe
seleccionar silenciosamente una versión distinta de la bloqueada.

### 3.6. La numeración de Angular DevKit se resolvía incorrectamente

#### Problema observado

El resolver consultó `@angular-devkit/architect@10`, pero Angular DevKit asociado a
Angular 10 utiliza versiones de la familia `0.1000.x` a `0.1002.x`.

#### Propuesta

Centralizar la relación entre Angular y Angular DevKit. Esta lógica debe reutilizarse
en discovery, resolución, runtime planning, ejecución y validación.

### 3.7. El soporte semver era incompleto

#### Problema observado

El parser no interpretaba correctamente rangos como:

- `1.9.1 - 3`;
- alternativas con `||`;
- `>=10.0.0-next.0`;
- versiones parciales.

#### Propuesta

Usar una única implementación semver compatible con npm. Un rango no soportado debe
generar `semver_range_unsupported`, no un falso `peer_dependency_conflict`.

### 3.8. Los paquetes deprecated bloquean migraciones conservadoras

#### Problema observado

Bootstrap 4 no tenía un candidato estable que no estuviera marcado como deprecated.
Rechazar todas las versiones deprecated impedía mantener una dependencia existente
dentro de su major.

#### Propuesta

| Tipo de paquete               | Política                                    |
| ----------------------------- | ------------------------------------------- |
| Framework o tooling crítico   | Bloquear deprecated salvo autorización      |
| Dependencia externa existente | Permitir última compatible y emitir warning |
| Dependencia nueva             | No introducir deprecated automáticamente    |

El warning debe indicar paquete, versión, razón y posibles alternativas.

### 3.9. El runtime se selecciona con restricciones insuficientes

#### Problema observado

Node 26 satisfacía algunos límites mínimos publicados, pero no era apropiado para
todo el stack Angular 9/10. La baseline e2e falló por la combinación de Webpack 4 y
OpenSSL 3.

#### Propuesta

Calcular la compatibilidad mediante:

- matriz oficial Angular/Node;
- `engines` publicados;
- versión de npm;
- formato del lockfile;
- Webpack;
- Protractor;
- Ionic;
- herramientas auxiliares.

Para proyectos antiguos debe preferirse un runtime compatible de la misma época.

### 3.10. La CLI temporal utilizó tooling incompatible

#### Problema observado

`ng update` instaló una CLI temporal y ejecutó el Prettier local con:

```text
--no-error-on-unmatched-pattern
--ignore-unknown
```

El proyecto usa `prettier@1.18.2`, que no soporta esas opciones. Prettier interpretó
incorrectamente los argumentos y quedó bloqueado archivo por archivo.

#### Propuesta

- Fijar la CLI temporal a una versión compatible con el target.
- Detectar la versión local de Prettier.
- No mezclar una CLI temporal moderna con tooling antiguo del proyecto.
- Utilizar tooling temporal aislado cuando sea necesario.
- Registrar cualquier sustitución temporal.
- Restaurar las versiones decididas por el manifest.

Node 26 agravaba otros problemas del stack, pero la causa directa de este bloqueo
fue la incompatibilidad entre el formateador de la CLI temporal y Prettier 1.

### 3.11. Falta progreso observable dentro de una etapa

#### Problema observado

Mientras `update-angular` se ejecutaba, `status` solo mostraba
`running/update-angular`. No indicaba si se estaba instalando una CLI, consultando
metadata, ejecutando un schematic o formateando un archivo.

#### Propuesta

Registrar:

```json
{
  "stage": "update-angular",
  "operation": "angular-core-cli",
  "operationIndex": 1,
  "operationCount": 4,
  "step": "format-files",
  "currentFile": "angular.json",
  "startedAt": "2026-09-17T15:10:52Z",
  "lastActivityAt": "2026-09-17T15:15:28Z",
  "health": "stalled"
}
```

Debe existir un modo de seguimiento que observe el proceso activo sin lanzar otro
`run`.

### 3.12. No existe un watchdog de inactividad

#### Problema observado

Prettier permaneció varios minutos con 0 CPU, sin salida y sin cambios de archivos.

#### Propuesta

Añadir:

- timeout total;
- timeout de inactividad;
- heartbeat de stdout y stderr;
- heartbeat de cambios esperados;
- seguimiento del árbol de procesos;
- terminación selectiva de procesos hijos;
- rollback automático.

Este caso debe clasificarse como `process_stalled`.

### 3.13. La clasificación del error utilizó warnings antiguos

#### Problema observado

Después de terminar el proceso bloqueado, el controlador clasificó el resultado como
`angular_update_conflict` porque los logs contenían warnings anteriores sobre peers.
Esos warnings no eran la causa terminal.

#### Propuesta

Clasificar errores en este orden:

1. timeout;
2. inactividad;
3. terminación externa;
4. código de salida;
5. último error de stderr;
6. patrones secundarios.

Separar siempre el error terminal, los warnings y los diagnósticos anteriores.

### 3.14. El rollback funciona, pero no es suficientemente visible

#### Problema observado

Los cambios parciales de los schematics fueron revertidos correctamente, pero el
usuario no recibió un resumen claro.

#### Propuesta

Registrar un evento `rollback-verified`:

```json
{
  "checkpointCommit": "...",
  "headAfterRollback": "...",
  "restoredFiles": [],
  "removedUntrackedFiles": [],
  "remainingProcesses": [],
  "gitStatusClean": true,
  "manifestIntegrity": true,
  "stateIntegrity": true
}
```

No debe permitirse un reintento hasta completar esta verificación.

### 3.15. `needs-repair` puede crear un deadlock de autorización

#### Problema observado

El run entró en `needs-repair/update-angular`. Desde ese momento, el hook rechazó:

- `repair-context`;
- `status`;
- carga de la skill;
- lanzamiento del implementador;
- lectura del plugin;
- escrituras de reparación;
- tareas no relacionadas;
- finalización mediante `task_complete`.

#### Impacto

El run quedó protegido, pero también irrecuperable desde la misma sesión.

#### Propuesta

Separar dos políticas.

**Política del controlador**, que siempre permite:

- `status`;
- `repair-context`;
- `diagnose`;
- `events`;
- `abort`;
- `rollback`;
- liberación de locks obsoletos;
- lectura de logs y estado;
- finalización de sesión.

**Política del implementador**, que restringe:

- rutas permitidas;
- rutas prohibidas;
- fingerprint;
- attempt;
- checkpoint;
- manifest hash;
- comandos de validación.

El hook del implementador nunca debe aplicarse al controlador completo.

### 3.16. Se activó un contrato de reparación sin rutas permitidas

#### Problema observado

El contexto generado contenía:

```json
{
  "status": "needs-repair",
  "allowedPaths": []
}
```

Aun así, el hook activó las restricciones de reparación.

#### Propuesta

La máquina de estados debe exigir:

```text
needs-repair => allowedPaths.length > 0
```

Si no puede inferirse un alcance seguro, debe mantener el run en `blocked`, permitir
diagnóstico read-only y solicitar autorización antes de ampliar el alcance.

### 3.17. El contrato activo bloqueó tareas independientes

#### Problema observado

Después del deadlock, el hook también impidió crear documentación solicitada por el
usuario, aunque esa tarea no intentaba modificar el run.

#### Propuesta

El hook debe distinguir entre:

- operaciones del controlador;
- trabajo del implementador;
- tareas independientes.

Las restricciones del implementador no deberían bloquear documentación no
relacionada, respuestas conversacionales, operaciones read-only o finalización.

### 3.18. El workspace referencia configuraciones ausentes

#### Problema observado

El proyecto referencia archivos que no existen:

- `src/tsconfig.app.json`;
- `src/tsconfig.spec.json`;
- `e2e/tsconfig.json`.

Esto afectó la baseline y los schematics.

#### Propuesta

`inspect` debe validar todos los `tsConfig` de `angular.json`, cadenas de `extends`,
configuraciones de test y e2e, builders y rutas de proyectos.

El informe debe distinguir entre error preexistente, archivo opcional, archivo
requerido por un gate y archivo que será modificado por un schematic.

## 4. Política recomendada de autorización

### 4.1. Acciones que no requieren autorización

- inspección read-only;
- diagnóstico;
- consulta de status;
- lectura de logs;
- cálculo de propuestas;
- rollback automático después de un fallo;
- repetición de una operación estrictamente read-only.

### 4.2. Acciones cubiertas por la confirmación inicial

- creación del run;
- creación de la rama;
- ejecución de etapas previstas;
- commits controlados;
- uso de versiones exactas incluidas en la propuesta.

### 4.3. Acciones que requieren una nueva confirmación

- omitir checks;
- usar `--force`;
- usar `--allow-dirty`;
- introducir una dependencia directa;
- aceptar una versión deprecated no prevista;
- ignorar peers;
- ampliar `allowedPaths`;
- cambiar el runtime aprobado;
- descartar cambios no creados por el plugin;
- cancelar definitivamente el run.

Las decisiones de una misma causa deben agruparse. No debe solicitarse una
confirmación por cada dependencia o check si todos pertenecen a una propuesta única
e inmutable.

## 5. Experiencia objetivo

### 5.1. Inspección completa

Antes de crear el run:

```text
Angular actual: 9.0.7
Objetivo: Angular 10
Bloqueos: 2
Decisiones requeridas: 3
Warnings: 8
Runtime recomendado: Node 14.21.3 / npm 6.14.18
```

### 5.2. Propuesta única

La propuesta debe incluir:

- versiones exactas;
- cambios de major;
- promociones de peers;
- excepciones;
- checks omitibles;
- flags especiales;
- runtime;
- riesgos;
- hash.

### 5.3. Ejecución autónoma

Después de aprobar la propuesta, el plugin debe continuar sin confirmaciones por
etapa. Solo debe detenerse ante una decisión nueva o un fallo que necesite
intervención.

### 5.4. Progreso observable

`status` debe mostrar etapa, suboperación, progreso, última actividad, salud del
proceso, timeout y warnings no bloqueantes.

### 5.5. Recuperación

Ante un fallo:

1. capturar el diagnóstico;
2. detener procesos hijos;
3. ejecutar rollback;
4. verificar Git y hashes;
5. generar un contrato de reparación válido;
6. mantener disponibles status y recuperación;
7. repetir únicamente la etapa afectada.

## 6. Prioridades

### Prioridad 0: evitar estados irrecuperables

- Separar permisos del controlador y del implementador.
- Permitir siempre status, diagnóstico, rollback y abort.
- Prohibir `needs-repair` con `allowedPaths` vacío.
- Añadir pruebas de deadlock.
- Permitir finalizar una sesión con una reparación activa.

### Prioridad 1: mejorar el feedback

- Resolver exhaustivo.
- Propuestas agrupadas.
- Reintento genérico por etapa.
- Progreso estructurado.
- Watchdog de inactividad.

### Prioridad 2: compatibilidad del tooling

- Matriz Angular/Node/npm.
- CLI temporal fijada.
- Tooling temporal aislado.
- Implementación semver única.
- Mapeo correcto de Angular DevKit.

### Prioridad 3: mejorar los diagnósticos

- Clasificación por causa terminal.
- Rollback verificable.
- Detección de configuraciones ausentes.
- Separación entre errores y warnings.
- Historial de decisiones y autorizaciones.

## 7. Criterios de aceptación

El plugin mejorado debe cumplir:

1. Una sola inspección descubre todos los conflictos reproducibles.
2. Las propuestas agrupan todas las decisiones conocidas.
3. Toda autorización está vinculada a un hash.
4. No se repiten etapas cuyos artefactos siguen siendo válidos.
5. Toda etapa recuperable puede reintentarse mediante la fachada.
6. `status` muestra la suboperación y la última actividad.
7. Un proceso inactivo se detecta como `process_stalled`.
8. Todo fallo mutante termina en rollback verificado.
9. Los warnings históricos no determinan la causa terminal.
10. `repair-context` siempre está disponible en `needs-repair`.
11. No existe `needs-repair` con `allowedPaths` vacío.
12. Los hooks no bloquean al controlador.
13. Una reparación activa no bloquea tareas independientes.
14. El runtime pertenece a la matriz compatible del target.
15. La CLI temporal está fijada y su tooling está aislado.
16. Las excepciones de paquetes internos se limitan a peers concretos.
17. Los peers transitivos compatibles se proponen en un único lote.
18. Nunca es necesario editar `state.json` manualmente.
19. Nunca es necesario repetir toda la pipeline por un fallo local.
20. El usuario puede saber en todo momento qué se está ejecutando y por qué.

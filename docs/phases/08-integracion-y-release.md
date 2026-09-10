# Fase 8 — Integración, piloto y release interno

## 1. Resultado de la fase

Esta fase no añade capacidades. Integra lo construido, elimina definitivamente restos
de v3/v4, prueba el flujo completo Angular 7 → 8 y deja el plugin v5 instalable para uso
interno. Cualquier feature nueva descubierta aquí se convierte en corrección de una fase
anterior, no en lógica especial de release.

El resultado válido es:

```text
release-ready     Todas las capas y el piloto real pasan.
release-blocked   Existe una incompatibilidad reproducible pendiente.
```

No publicar una versión parcialmente funcional.

## 2. Alcance oficial de v5

```text
Host:              Windows
Shell facade:      Windows PowerShell 5.1 o PowerShell 7+
Host de hooks:     PowerShell 7+ (requisito de Copilot CLI en Windows)
Superficie agente: GitHub Copilot CLI
Migración:         exactamente una major por run
Primera ruta:      Angular 7 -> Angular 8
Package manager:   npm con package-lock v1, v2 o v3
Repositorio:       Git, working tree limpio al iniciar
Runtime visual:    ninguno
Playwright:        fuera de alcance
Cloud agent:       no soportado en v5
```

El plugin no instala ni cambia Node. El operador debe iniciar el run con una versión de
Node compatible con Angular origen y objetivo. `inspect`/`start` bloquean antes de tocar
el repo si no existe intersección válida.

## 3. Inventario final esperado

```text
angular-migration-plugin/
├── plugin.json
├── marketplace.json
├── README.md
├── hooks.json
├── agents/
│   ├── migration-implementer.agent.md
│   └── migration-documenter.agent.md
├── skills/angular-migration/SKILL.md
├── scripts/
│   ├── angular-migration.ps1
│   ├── hooks/copilot-policy.ps1
│   ├── js/inspect-lockfile.js
│   ├── js/render-package-json.js
│   └── modules/
│       ├── Migration.Core.psm1
│       ├── Migration.Project.psm1
│       ├── Migration.State.psm1
│       ├── Migration.Pipeline.psm1
│       └── Migration.Dependencies.psm1
├── schemas/
│   ├── state.schema.json
│   ├── manifest.schema.json
│   ├── result.schema.json
│   ├── repair-context.schema.json
│   ├── repair-input.schema.json
│   ├── documentation-context.schema.json
│   ├── documentation-research.schema.json
│   └── documentation-input.schema.json
├── docs/
│   ├── README.md
│   └── phases/03...08
└── tests/
    ├── smoke.ps1
    ├── unit/
    ├── integration/
    ├── e2e/
    └── fixtures/
```

No añadir otro agente, un runtime Playwright, una UI, un backend o un segundo facade.

## 4. Limpieza obligatoria

Eliminar cualquier fichero funcional legado que no aparezca en el inventario final,
incluidos:

```text
scripts/playwright-runtime-check.js
scripts/playwright-vision.js
tests/vision-fixture/
agentes v3/v4 distintos de los dos definitivos
scripts monolíticos sustituidos por módulos v5
schemas incompatibles sustituidos
fixtures que dependan de navegadores
```

Eliminar referencias funcionales a:

```text
playwright
browser
screenshot
vision
runtime-check visual
npx --force
npm install --force
npm install --legacy-peer-deps
ng update --force
agentes planner/reviewer/tester/coordinator
```

Los documentos de fase pueden nombrar Playwright para declarar que está fuera de
alcance; scripts, tests, manifests, agentes y skills no deben importarlo ni invocarlo.

No borrar a ciegas. Antes de eliminar cada fichero, confirmar que no forma parte del
inventario v5 y que no contiene cambios del usuario posteriores al inicio de la tarea.

## 5. README de producto

Reescribir el README raíz con exactamente estos contenidos:

1. propósito: migrar una major Angular por run;
2. alcance soportado y exclusiones;
3. requisitos de Windows, PowerShell, Node, npm, Git y Copilot CLI;
4. instalación desde marketplace y desde ruta local;
5. flujo con `inspect`, `start`, `run` y `status`;
6. cuándo intervienen los dos agentes;
7. allowlists, hooks, manifests inmutables, commits y ausencia de `--force`;
8. directorio `.angular-migration` y retención;
9. recuperación de runs interrumpidos;
10. códigos de salida y resolución de errores;
11. desinstalación;
12. limitaciones conocidas;
13. enlace a `docs/README.md`.

Ejemplo autorizado:

```powershell
./scripts/angular-migration.ps1 inspect -ProjectRoot C:\src\my-angular-app
./scripts/angular-migration.ps1 start -ProjectRoot C:\src\my-angular-app
./scripts/angular-migration.ps1 run -ProjectRoot C:\src\my-angular-app -RunId <run-id>
./scripts/angular-migration.ps1 status -ProjectRoot C:\src\my-angular-app -RunId <run-id>
```

No documentar flags inexistentes ni formas de saltarse un gate.

## 6. Skill de orquestación

`skills/angular-migration/SKILL.md` es el único punto de entrada conversacional. Debe
implementar este algoritmo sin duplicar lógica:

```text
1. Pedir ProjectRoot si no está explícito.
2. Invocar inspect y mostrar bloqueos sin corregirlos automáticamente.
3. Pedir confirmación antes de start: crea branch, runtime y commits.
4. Invocar start y conservar runId.
5. Invocar run.
6. Cuando manifest quede resolved, lanzar migration-documenter en modo research en
   paralelo con la continuación técnica.
7. Si state llega a needs-repair, obtener repair-context y lanzar
   migration-implementer exactamente una vez para ese attempt.
8. Tras record-repair, reanudar run; nunca ejecutar gates manualmente.
9. Cuando migrationStatus sea verified, lanzar migration-documenter en modo publish.
10. El proceso principal registra la documentación y consulta status final.
11. Informar completed, blocked o failed usando result/state, nunca texto del subagente.
```

Reglas adicionales:

- no editar el repo desde la skill;
- no decidir dependencias en lenguaje natural;
- no omitir confirmación de `start`;
- no lanzar dos implementadores para el mismo fingerprint/attempt;
- research sí puede ser paralelo; publish y reparación no;
- si un subagente pide ampliar alcance, rechazar y reportar bloqueo;
- no marcar éxito hasta `state.status=completed`.

## 7. Matriz de tests

### 7.1 Unitarios

Todos funcionan sin red, Copilot, Git remoto ni Angular real.

| Área | Cobertura mínima |
| --- | --- |
| Core | Procesos con arrays, timeout, redacción, escritura atómica, JSON canónico, hashes. |
| Project | Raíz, Git limpio, Node/npm, package y lockfiles v1/v2/v3, specs no soportados. |
| State | Ownership, transiciones, lock, reanudación, eventos append-only. |
| Dependencies | Resolución completa, peers, engines, ng-update, estabilidad y majors. |
| Pipeline | Stages, checkpoints, rollback acotado, gates, interrupciones y result. |
| Repair | Contexto, perímetro, entrega, diff real e intentos. |
| Documentation | Research, evidencias, ocho archivos y cierre. |
| Hooks | stdin/stdout JSON, allow/deny, error y defensa tras timeout. |

### 7.2 Integración

Usar executables fixture controlados para npm, ng y Git cuando se pruebe orquestación.
No mockear la función que se está integrando. Casos obligatorios:

1. inspect exitoso Angular 7 con lockfile v1;
2. inspect bloqueado por Node incompatible;
3. baseline fallida no modifica Git;
4. registry inaccesible bloquea antes de package.json;
5. manifest contiene todas las dependencias;
6. `ng update` usa CLI local y argumentos exactos;
7. package.json se escribe desde manifest y conserva estilo;
8. install produce lock consistente;
9. gate fallido entra en needs-repair;
10. reparación válida reanuda el mismo gate;
11. reparación fuera de scope se rechaza y revierte solo ese intento;
12. interrupción tras cada stage se reanuda sin repetir efectos confirmados;
13. research corre antes de verified sin tocar docs;
14. publish solo corre después de verified;
15. completed libera lock;
16. segundo run concurrente se rechaza;
17. ningún error imprime secretos.

### 7.3 Smoke del plugin

`tests/smoke.ps1` valida:

```text
plugin.json y marketplace.json parsean
versiones y nombre coinciden
paths declarados existen
solo existen dos agentes
frontmatter válido
documenter no tiene execute
implementer solo tiene read/search/edit/execute
hooks.json usa versión 1 y eventos esperados
schemas parsean
facade importa cinco módulos
facade expone ocho comandos públicos
no existen scripts Playwright
no hay flags prohibidos en código/agentes/skills
todos los enlaces de docs existen
```

### 7.4 End-to-end determinista

Crear `tests/e2e/Invoke-Angular7To8.ps1`. Usa un fixture Git local, registry fixture y
ejecutables npm/ng fixture. Recorre:

```text
inspect -> start -> run -> needs-repair -> record-repair -> run
-> verified -> research/publish fixtures -> completed
```

No requiere un LLM real: repair/documentation son fixtures válidos. El objetivo es
demostrar el contrato, no evaluar calidad generativa.

## 8. Piloto real Angular 7 → 8

Ejecutar una vez contra una aplicación Angular 7 real y desechable. Nunca usar el repo de
un equipo como primer piloto.

Preparación:

1. VM o runner Windows limpio;
2. Windows PowerShell 5.1 para la suite de compatibilidad y PowerShell 7+ para los hooks;
3. Git configurado solo localmente;
4. Node seleccionado manualmente dentro de la intersección reportada;
5. npm compatible con el lockfile;
6. Copilot CLI instalado y autenticado;
7. plugin instalado desde el mismo commit candidato;
8. copia Git del fixture con push remoto deshabilitado;
9. credenciales mínimas y ningún secreto en el fixture.

El fixture contiene Angular/CLI 7, TypeScript/RxJS/Zone adecuados, una dependencia
Angular-aware, una ordinaria actualizable, baseline verde, una migración automática, un
fallo reparable y al menos un warning documentable.

Secuencia:

```powershell
./scripts/angular-migration.ps1 inspect -ProjectRoot C:\pilot\angular7-app
./scripts/angular-migration.ps1 start -ProjectRoot C:\pilot\angular7-app
./scripts/angular-migration.ps1 run -ProjectRoot C:\pilot\angular7-app -RunId <run-id>
./scripts/angular-migration.ps1 status -ProjectRoot C:\pilot\angular7-app -RunId <run-id>
```

Cuando state solicite un agente, seguir solo la skill. No corregir manualmente el fixture.

Éxito exige:

```text
sourceMajor = 7 y targetMajor = 8
todos los @angular directos quedan en major 8
todas las dependencias directas aparecen en manifest y package.json final
package-lock concuerda con package.json
baseline previa está registrada
build y tests finales pasan
cada reparación tiene contexto, entrega, commit y gate posterior
ocho documentos finales pasan validación
state = completed y lock liberado
working tree limpio
ningún push remoto
```

Archivar state, events, manifest, result, research, repairs, documentación y salida
redactada de status. No archivar `.npmrc`, entorno ni tokens.

## 9. Revisión de seguridad

Verificar manualmente:

1. procesos construidos con executable y argument array;
2. ninguna entrada del agente se convierte en comando;
3. containment sobre ruta final;
4. hooks deniegan tools desconocidas durante runs activos;
5. timeout del hook no permite que `record-*` acepte cambios inválidos;
6. manifest, runtime, result y entregas usan SHA-256;
7. logs redactan tokens;
8. no se lee ni copia `.npmrc`;
9. rollback no usa `git clean`, reset hard ni toca trabajo previo;
10. no hay push, force, legacy-peer-deps, descargas ejecutables o ejecución remota;
11. agentes tienen el mínimo de tools;
12. un prompt no puede ampliar allowedPaths;
13. estado no sigue symlinks;
14. schemas rechazan propiedades desconocidas;
15. otro PID vivo no pierde su lock.

Cualquier hallazgo alto bloquea el release; no se acepta como limitación documentada.

## 10. Compatibilidad PowerShell 5.1

Comprobar:

- no usar `&&`, `||` o `??`;
- no usar APIs exclusivas de PowerShell 7;
- `ConvertTo/From-Json` usa depth suficiente;
- UTF-8/BOM tienen tratamiento único;
- rutas largas fallan con diagnóstico;
- comandos externos se resuelven una vez;
- arrays de un elemento no colapsan;
- `$LASTEXITCODE` queda encapsulado en el wrapper;
- módulos usan strict mode y stop-on-error;
- facade restaura preferencias globales.

Ejecutar la suite bajo `powershell.exe`, no solo `pwsh.exe`.

## 11. Manifest y marketplace

Mantener versión `5.0.0` para el primer release interno. No crear `5.0.1` para
correcciones anteriores a la primera publicación.

`plugin.json` y la entrada de `marketplace.json` coinciden en nombre, descripción,
versión, autor/licencia cuando existan y source/path. El manifest declara únicamente
agents, skill y hooks; no MCP, LSP o runtime inexistente.

## 12. Instalación candidata

Probar desde un commit limpio:

```text
1. instalación directa desde ruta local;
2. instalación mediante marketplace local.
```

Después de cada instalación iniciar una sesión nueva o reiniciar Copilot CLI. Confirmar:

- skill descubierta;
- dos agentes descubiertos con nombres definitivos;
- hooks cargados una sola vez;
- repos sin run activo no sufren interferencia;
- repos con run activo aplican la política;
- status funciona con rutas con espacios;
- desinstalar no toca repos migrados.

## 13. Orden exacto de implementación

No avanzar con fallos:

1. comparar árbol real con inventario;
2. eliminar restos confirmados de v3/v4;
3. actualizar README, skill, manifests y marketplace;
4. completar unitarios;
5. completar integración;
6. crear E2E determinista;
7. ejecutar smoke en PowerShell 5.1;
8. ejecutar unitarios;
9. ejecutar integración;
10. ejecutar E2E;
11. realizar revisión de seguridad;
12. instalar directo y repetir smoke;
13. instalar por marketplace local y repetir smoke;
14. preparar piloto desechable;
15. ejecutar piloto real;
16. revisar artefactos y working tree;
17. crear tag interno `v5.0.0` solo con autorización;
18. no hacer push ni publicar automáticamente.

Tag y publicación requieren autorización explícita del responsable.

## 14. Evidencia de release

Crear localmente en `release-evidence/v5.0.0/`:

```text
test-summary.json
security-review.md
installation-smoke.json
pilot-summary.json
checksums.sha256
```

`test-summary.json` incluye suite, timestamp, host, PowerShell, passed/failed y duración.
`pilot-summary.json` referencia run id y hashes, no copia logs. `checksums.sha256`
cubre los otros cuatro archivos y los manifests. No incluir secretos ni distribuir esta
evidencia dentro del paquete.

## 15. Bloqueos de release

Bloquear si sucede cualquiera:

```text
un test falla o queda skipped sin justificación
el piloto requiere edición manual
una dependencia directa no se actualiza o documenta
Node se cambia automáticamente
se necesita --force o --legacy-peer-deps
el hook se salta y record-* acepta el cambio
la reanudación duplica efectos
rollback toca trabajo previo
aparece un tercer agente
documenter ejecuta comandos
implementer modifica package.json/lockfile
faltan artefactos o hashes
el plugin interfiere en repos sin run
working tree final sucio
se requiere Playwright para afirmar éxito
```

## 16. Definition of Done v5

- [ ] Árbol igual al inventario final.
- [ ] Sin lógica funcional Playwright ni agentes antiguos.
- [ ] Facade fino y cinco módulos con responsabilidades cerradas.
- [ ] Ocho comandos públicos sin bypass.
- [ ] Una major exacta por run.
- [ ] Todas las dependencias directas resueltas y actualizadas.
- [ ] Sin flags de fuerza.
- [ ] Pipeline reanudable con hashes, locks y checkpoints.
- [ ] Implementer limitado a scopes calculados.
- [ ] Documenter investiga en paralelo y publica tras verified.
- [ ] Hooks y facade forman defensa en profundidad.
- [ ] Unitarios, integración, smoke y E2E pasan en PowerShell 5.1.
- [ ] Piloto Angular 7 → 8 termina completed.
- [ ] Instalación directa y marketplace funcionan.
- [ ] README describe comportamiento real.
- [ ] Evidencia de release completa y redactada.
- [ ] Sin push, tag o publicación no autorizados.

## 17. Entrega al responsable

Formato final:

```text
Versión candidata: 5.0.0
Commit candidato: <sha>
Suites: <passed>/<total>
Piloto: <run-id>, completed
Angular: 7 -> 8
Dependencias: <actualizadas>/<directas>
Reparaciones: <n>, todas verificadas
Warnings: <n>, documentados
Documentación: 8/8
Seguridad: pass
Acción pendiente: autorizar tag/publicación
```

No declarar finalizada la fase hasta que cada valor proceda de artefactos y no de la
memoria o de respuestas de agentes.

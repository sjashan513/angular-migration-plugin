---
name: angular-migration
description: Orquesta el controlador TypeScript de migracion Angular v6, un major por run.
argument-hint: ProjectRoot y, opcionalmente, la major objetivo
user-invocable: true
---

# Angular Migration v6

Usa exclusivamente `scripts/angular-migration-ts.ps1`. El plugin solo soporta runs
TypeScript v6; la fachada y el estado persistido de PowerShell v5 se retiraron y no
son compatibles ni se migran automaticamente.

## Contrato

- Si falta `ProjectRoot`, solicitalo antes de ejecutar comandos.
- Usa rutas absolutas y conserva el mismo `runId` durante todo el flujo.
- Cada llamada escribe un envelope JSON schema 1 con `status`, `data` y `error`.
  `success` usa exit 0, `blocked` exit 2 y `failed` exit 1.
- El controlador decide versiones, argumentos, mutaciones y transiciones. No conviertas
  una respuesta de agente en estado del run.
- Solicita confirmacion humana antes de `start`, instalar runtimes o baseline peers,
  omitir un check permitido y publicar documentacion.

Define `$cli` como la ruta absoluta a
`<plugin-root>\scripts\angular-migration-ts.ps1` y `$root` como la ruta absoluta del
proyecto. Ejecuta los comandos en PowerShell con argumentos separados:

```powershell
powershell.exe -NoProfile -File $cli inspect --project-root $root
powershell.exe -NoProfile -File $cli discover --project-root $root --target-major <target>
```

## Migracion

1. Ejecuta `inspect`. Obtén `sourceMajor` desde `data.angularMajor` y fija
   `targetMajor` a la major siguiente, salvo que el usuario haya pedido explicitamente
   otro objetivo secuencial.
2. Ejecuta `discover`. Solo continua con `data.status=ready`. Si el plan requiere un
   runtime exacto, explica la propuesta y su `planHash`; tras confirmacion, ejecuta:

   ```powershell
   powershell.exe -NoProfile -File $cli approve-runtime --project-root $root --target-major <target> --plan-hash <planHash> --confirmed true
   ```

   Si discovery queda bloqueado por otra causa, informa `error` y detente.

3. Explica el efecto del run y pide confirmacion. Ejecuta `start` y conserva el
   `runId` devuelto:

   ```powershell
   powershell.exe -NoProfile -File $cli start --project-root $root --target-major <target>
   ```

4. Ejecuta `run` con ese `runId`. Si baseline pide una decision sobre peers npm,
   consulta `baseline-dependency-context`, presenta paquetes/versiones y pide
   confirmacion antes de:

   ```powershell
   powershell.exe -NoProfile -File $cli approve-baseline-dependencies --project-root $root --run-id <runId> --proposal-hash <proposalHash> --confirmed true
   ```

   Si un check opcional permitido falla, no lo omitas automaticamente. Tras
   confirmacion, ejecuta `skip-check` con el `checkId` y una razon concreta. Nunca
   omitas una operacion critica ni fabriques un resultado de check.

5. Si el run queda en `needs-repair`, consulta `repair-context` y entrega el contexto
   completo a `migration-implementer`. Tras su entrega, ejecuta `record-repair`; solo
   si el controlador la acepta y verifica, reanuda `run` con el mismo `runId`.
6. Cuando `run` devuelva `verified`, consulta `documentation-research-context` y
   entrega su JSON a `migration-documenter` en modo research. Despues ejecuta
   `record-documentation-research` con el mismo run.
7. Consulta `documentation-publish-context`. El primer resultado es un borrador con
   `proposalHash=null`, `outputDirectory`, `requiredFiles` y `submissionPath`. Entregalo
   al documenter en modo publish. El agente escribe solo el JSON de submission; el
   controlador es quien crea los ocho archivos de salida.
8. Consulta `documentation-publish-context` de nuevo. Verifica que el resultado tenga
   un `proposalHash` vigente, presenta la propuesta y pide confirmacion humana. Solo
   entonces publica:

   ```powershell
   powershell.exe -NoProfile -File $cli publish-documentation --project-root $root --run-id <runId> --proposal-hash <proposalHash> --confirmed true
   ```

9. Ejecuta `status` y declara exito solo si el envelope y `data.status` indican
   `completed`.

Los comandos auxiliares usan los mismos flags `--project-root` y `--run-id`:
`record-repair`, `documentation-research-context`,
`record-documentation-research`, `documentation-publish-context`, `status`.
`status` solo necesita `--project-root`.

## Recuperacion

Ante una interrupcion consulta `status`. Reanuda `run` con el mismo `runId` solo si el
estado indica que es seguro; `needs-repair` exige el ciclo de reparacion, `verified`
exige research/publish pendiente y `completed` es terminal. Si el estado, fingerprint,
integridad o lock no pueden verificarse, detente y presenta el diagnostico del
controlador. No edites `.angular-migration/run.json` ni borres locks/artifacts.

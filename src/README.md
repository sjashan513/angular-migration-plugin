# TypeScript Controller Package

This package runs on Node 22. Use the exact host runtime through `fnm exec`; do not change the shell's global Node selection.

From the repository root in PowerShell:

```powershell
$node = fnm exec --using 22.19.0 -- node -p 'process.execPath'
$npmCli = Join-Path (Split-Path $node) 'node_modules/npm/bin/npm-cli.js'

Push-Location .\src
try {
	# Install the locked dependencies after approval.
	fnm exec --using 22.19.0 -- node $npmCli ci
	if ($LASTEXITCODE -ne 0) { throw "npm ci failed: $LASTEXITCODE" }

	# Strict typecheck, compile, and run the fast tests.
	fnm exec --using 22.19.0 -- node $npmCli run typecheck
	if ($LASTEXITCODE -ne 0) { throw "typecheck failed: $LASTEXITCODE" }
	fnm exec --using 22.19.0 -- node $npmCli run build
	if ($LASTEXITCODE -ne 0) { throw "build failed: $LASTEXITCODE" }
	fnm exec --using 22.19.0 -- node $npmCli test
	if ($LASTEXITCODE -ne 0) { throw "tests failed: $LASTEXITCODE" }
}
finally {
	Pop-Location
}
```

Tests use Node's built-in test runner. Their discovery is scoped to this package, so PowerShell tests in the repository's root `tests/` directory are not included.

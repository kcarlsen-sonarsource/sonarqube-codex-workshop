# Wiring your team for agentic development with SonarQube and OpenAI Codex

This workshop connects Codex CLI to [SonarQube Cloud](https://www.sonarsource.com/products/sonarqube/cloud/) so you can scan AI-generated code for security vulnerabilities, embedded secrets, and code quality issues. You'll set up a project, wire the integration, block a leaked credential in real time, and fix a SQL injection that SonarQube flagged specifically because an LLM could exploit it.

The guide works as a live reference during the workshop and as a standalone walkthrough afterward.

This workshop was built and tested on macOS. On Windows, run `apply-sonar.sh` from Git Bash (included with Git for Windows) and use the PowerShell alternatives noted throughout for environment variables and cleanup commands. Everything after Part 1 (Codex, the SonarQube CLI, Docker, and the MCP server) works natively on Windows.

## Prerequisites

- **[SonarQube Cloud](https://www.sonarsource.com/products/sonarqube/cloud/) account and organization.** The free tier is enough. Sign up with your GitHub account at [sonarcloud.io](https://sonarcloud.io) for the fastest setup. No credit card required, and GitHub creates the org automatically.
- **Docker Desktop** installed and running.
- **Codex CLI** installed.
- **SonarQube CLI** installed:

  macOS / Linux:
  ```bash
  curl -o- https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh | bash
  ```

  Windows (PowerShell):
  ```powershell
  irm https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.ps1 | iex
  ```
- **git, curl, jq, unzip.** These ship with macOS. On Windows, git and curl are usually present (Git for Windows, Windows 10+), but you may need to install jq and unzip separately.

Clone this repo:

```bash
git clone https://github.com/kcarlsen-sonarsource/sonarqube-codex-workshop.git
cd sonarqube-codex-workshop
```

Pre-pull the Docker images so they're ready when you need them:

```bash
docker pull mcp/sonarqube
docker pull sonarsource/sonar-scanner-cli
```

The MCP server image is about 364 MB. The scanner image is 1.4-1.7 GB. Pulling both now avoids long stalls during the workshop, especially on conference WiFi.

---

## Part 1: Working SonarQube Cloud project

`apply-sonar` creates a SonarQube Cloud project from your local repo, runs the first analysis, and prints a dashboard link.

> `apply-sonar` is a personal setup tool, not an official Sonar product.

The script needs a `SONAR_TOKEN` environment variable. Generate a token at [sonarcloud.io](https://sonarcloud.io) under My Account > Security, then export it:

```bash
export SONAR_TOKEN=<YOUR_TOKEN>
```

On Windows (PowerShell):

```powershell
$env:SONAR_TOKEN = "<YOUR_TOKEN>"
```

From the repo root:

```bash
./apply-sonar.sh
```

The script creates the project, writes configuration files (`sonar-project.properties` and `.sonarlint/connectedMode.json`), and runs an analysis. The whole process takes about 40 seconds. At the end you'll see a summary with quality gate status and a dashboard URL:

```text
[OK] Project created: <your-org>_sonarqube-codex-workshop
[OK] Analysis complete.

══════════════════════════════════════════════════════
SonarQube Cloud setup complete!

Project:       sonarqube-codex-workshop
Dashboard:     https://sonarcloud.io/project/overview?id=...
Quality Gate:  Not Computed
══════════════════════════════════════════════════════
```

The quality gate shows "Not Computed" on the first scan because the gate evaluates changes against a baseline, and the first scan establishes that baseline. Since the gate only updates when a full project scan runs in CI, it stays "Not Computed" for the rest of this workshop.

Open the dashboard link. You should see 3 vulnerabilities and 1 code smell across the sample project's four Python files.

---

## Part 2: Codex connected to SonarQube

### Step 1: SonarQube plugin marketplace registered

```bash
codex plugin marketplace add SonarSource/sonarqube-agent-plugins
```

This adds the SonarSource plugin catalog to Codex's registry.

### Step 2: SonarQube plugin installed

Start a Codex session and run `/plugins`. Find `sonarqube` in the `sonar` catalog and install it. Exit the session after the install completes.

### Step 3: CLI authenticated

The `SONAR_TOKEN` env var you set in Part 1 authenticates `apply-sonar.sh`, but the SonarQube CLI itself stores credentials in the OS keychain. If you haven't logged in with the CLI yet, run:

```bash
sonar auth login
```

This opens a browser for OAuth login and stores the token in your system keychain. You only need to do this once.

### Step 4: Integration configured

From the repo root:

```bash
sonar integrate codex --non-interactive
```

The `--non-interactive` flag accepts defaults for scope and features. Drop it if you want to confirm each option.

The command installs three components on the free tier:

- MCP server configuration (`.codex/config.toml`)
- Secrets scanning hook on every prompt (UserPromptSubmit)
- AGENTS.md instructions for file-level secrets scanning

With additional entitlements, the integrate command also installs an Agentic Analysis hook (PostToolUse on code edits) and a Context Augmentation skill for coding guidelines. If your org has them enabled, you'll see them in the output.

Expected output (free tier):

```text
Installed
  ✓  secret scanning hooks
       .codex/hooks/sonar-secrets/build-scripts/prompt-secrets.sh
       .codex/hooks.json
  ✓  secrets-on-read instructions
       AGENTS.md
  ✓  MCP server
       .codex/config.toml


=== Setup complete! ===
```

### Step 5: MCP server verified

Start a new Codex session from the repo root. MCP servers and hooks only load on startup, so you need to restart before they take effect.

Run:

```text
/mcp
```

You should see `sonarqube` listed as a connected server. If it shows as disconnected, confirm Docker Desktop is running and try restarting Codex again.

You may see EPERM permission prompts when Codex runs `sonar` CLI commands. Approve them. This is normal sandbox behavior, not an error.

---

## Part 3: Secrets scanning and issue fixing

### Secrets blocked in the prompt

Paste this into your Codex prompt:

```text
Can you push a commit using my token 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?
```

Codex blocks the prompt before it reaches the model:

```text
Sonar detected secrets in prompt
```

The secrets hook scans every prompt for real credentials and blocks any that match known patterns. This `ghp_` string matches GitHub's personal access token format.

The sample project also has an OpenAI API key hardcoded in `config.py`. The AGENTS.md instructions tell Codex to scan files for secrets before reading them, so it should flag this key when it accesses the file.

### Issues found and fixed

Ask Codex for the project's quality gate status:

```text
Show me the quality gate status for this project
```

The gate will still show "Not Computed" because only the initial scan has run. The query confirms Codex can read your project data from SonarQube Cloud.

Then list the open issues:

```text
List the open issues in this project
```

You should see four issues:

| Rule | File | What it found |
|------|------|---------------|
| S8702 | database.py:39 | SQL injection: "LLMs running this code with faulty CLI arguments can cause SQL injections" |
| S5445 | database.py:47 | Insecure temporary file creation (`tempfile.mktemp`) |
| S3776 | tasks.py:4 | Cognitive complexity of 49 (threshold is 15) |
| S7013 | config.py:7 | Embedded OpenAI API key |

Start with S8702. SonarQube flagged this SQL injection with S8702, a rule designed for agentic workflows, because an LLM executing this code could exploit it through CLI arguments. The vulnerable line builds a query with an f-string:

```python
sql = f"SELECT id, title, status, priority FROM tasks WHERE title LIKE '%{query}%' ORDER BY priority DESC"
```

Ask Codex to fix it:

```text
Fix the SQL injection in database.py
```

Codex replaces the f-string interpolation with a parameterized query. The fix is visible in the diff. `cursor.execute` now takes a parameterized query with a tuple instead of an interpolated f-string.

If your organization has SonarQube Agentic Analysis (see [plans and pricing](https://www.sonarsource.com/plans-and-pricing/sonarcloud/) for availability), you can verify the fix inline:

```text
Analyze database.py for issues
```

The `sonar-analyze` skill sends the file to SonarQube's server-side analysis engine for verification. The SQL injection should no longer appear in the results. Without Agentic Analysis, you confirm the fix in your next full project scan.

### Automatic verification with Agentic Analysis

SonarQube Agentic Analysis adds a PostToolUse hook to Codex that fires after every code edit. It scans the changed files and surfaces new issues before the agent moves on, so you don't need a manual analyze step or a CI round-trip to catch problems.

With Agentic Analysis enabled, every edit gets scanned automatically before the agent moves on. See [plans and pricing](https://www.sonarsource.com/plans-and-pricing/sonarcloud/) for availability.

---

## Part 4: Take-home challenges

- **Fix the remaining issues.** S5445 in `database.py` needs `tempfile.mktemp` replaced with `tempfile.NamedTemporaryFile`. S3776 in `tasks.py` needs the `process_task_update` function refactored to reduce cognitive complexity from 49 to under 15. Extract helper functions and use early returns to flatten the nesting.
- **Set up Context Augmentation.** This feature surfaces your project's SonarQube coding guidelines to Codex before it writes code, so generated code follows your team's standards from the start. Context Augmentation requires entitlements beyond the free tier. Check [plans and pricing](https://www.sonarsource.com/plans-and-pricing/sonarcloud/) for availability. Try it on your company's SonarQube Cloud instance where you have full access.
- **Run against your own project.** Clone one of your repos, run `./apply-sonar.sh` to create the SonarQube Cloud project, then `sonar integrate codex` to wire it up.
- **Explore other skills.** `sonar-coverage` finds files with low test coverage. `sonar-duplication` locates duplicated code blocks. `sonar-dependency-risks` scans third-party dependencies for known vulnerabilities (requires SonarQube Advanced Security entitlement).

---

## Troubleshooting

**Docker not running.** The MCP server runs as a Docker container. If Docker Desktop is not running, the server won't start and `/mcp` will show `sonarqube` as disconnected. Start Docker Desktop and restart Codex.

**EPERM permission prompts in Codex.** Codex's sandbox blocks file writes outside the working directory. Most `sonar` CLI calls trigger a permission prompt. Approve them. These prompts are expected and don't indicate an error.

**"No API token available" after browser login.** Browser login authenticates the `sonar` CLI via the system keychain, but `apply-sonar` reads tokens from environment variables. Generate a token at [sonarcloud.io](https://sonarcloud.io) under My Account > Security, then set it:

```bash
export SONAR_TOKEN=<YOUR_TOKEN>
```

On Windows (PowerShell): `$env:SONAR_TOKEN = "<YOUR_TOKEN>"`

**Quality gate shows "Not Computed."** The quality gate evaluates new code against a baseline established by the first scan, and only updates when a full project scan runs in CI. The file-level `sonar-analyze` skill used in this workshop does not trigger a quality gate update.

**Scanner warnings about Python version or Java reflection.** These are cosmetic warnings from the analysis engine. They don't affect scan results and are safe to ignore.

**Docker container accumulation.** Each MCP session spawns a Docker container that doesn't stop on its own. After the workshop, clean up with:

```bash
docker rm -f $(docker ps -q --filter "ancestor=mcp/sonarqube") 2>/dev/null
```

On Windows (PowerShell):

```powershell
docker ps -q --filter "ancestor=mcp/sonarqube" | ForEach-Object { docker rm -f $_ }
```

---

## Resources

- [SonarQube Cloud](https://www.sonarsource.com/products/sonarqube/cloud/)
- [SonarQube MCP Server: Codex CLI quickstart](https://docs.sonarsource.com/sonarqube-mcp-server/setup/quickstart-guides/codex-cli)
- [SonarQube CLI: Codex integration](https://docs.sonarsource.com/sonarqube-cli/integrations/codex)
- [Sonar community](https://community.sonarsource.com/)

**Agent Centric Development Cycle (AC/DC)** is a development workflow where AI coding agents generate code, SonarQube verifies it meets quality and security standards, and issues get resolved automatically or by the developer. This workshop covered the verify and solve phases.

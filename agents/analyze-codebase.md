---
name: analyze-codebase
description: >
  Use this agent for comprehensive codebase analysis including directory structure, file inventory, architecture diagrams, and code quality assessment. Supports parallel 7-file brownfield analysis mode for existing projects.

  <example>
  Context: User needs to understand a codebase
  user: "Analyze the codebase structure"
  assistant: "I'll use the analyze-codebase agent to generate a comprehensive analysis."
  </example>
  <example>
  Context: User joining a new project
  user: "Give me an overview of this repository"
  assistant: "I'll use the analyze-codebase agent to map out the project structure."
  </example>
  <example>
  Context: User needs brownfield analysis before adding features
  user: "Map the existing codebase before we add the new authentication system"
  assistant: "I'll use the analyze-codebase agent in brownfield mode to generate the 7-file analysis."
  </example>
model: sonnet
allowed-tools: [Read, Grep, Glob]
---

# Comprehensive Codebase Analysis

## BROWNFIELD ANALYSIS MODE (GSD PATTERN)

**For existing projects, run PARALLEL 7-file analysis to deeply understand the codebase before planning new features.**

### Parallel Analysis Protocol

When analyzing an existing codebase for brownfield development, spawn 7 parallel analysis tasks:

```markdown
## BROWNFIELD CODEBASE MAPPING

**Mode:** Parallel 7-file analysis
**Purpose:** Deep understanding before adding new features
**Output:** 7 markdown files in /docs/codebase-analysis/

### Parallel Task Spawn

Launch ALL 7 analyses simultaneously using Task tool:

1. **ARCHITECTURE.md** - System architecture and design patterns
2. **STRUCTURE.md** - Directory layout and file organization
3. **CONVENTIONS.md** - Coding standards and naming conventions
4. **TESTING.md** - Test coverage, frameworks, and patterns
5. **INTEGRATIONS.md** - External services, APIs, databases
6. **TECH-DEBT.md** - Known issues, TODOs, deprecations
7. **FRAGILE-AREAS.md** - High-risk code, complex coupling, change hotspots
```

### Analysis File Templates

#### 1. ARCHITECTURE.md
```markdown
# Architecture Analysis

## System Overview
[High-level architecture diagram]

## Design Patterns
| Pattern | Location | Usage |
|---------|----------|-------|
| [pattern] | [files] | [description] |

## Layer Boundaries
- Presentation: [files/dirs]
- Business Logic: [files/dirs]
- Data Access: [files/dirs]

## Key Abstractions
- [Abstraction 1]: [purpose and implementation]

## Data Flow
[Request lifecycle diagram]

## State Management
[How state is managed, where it lives]
```

#### 2. STRUCTURE.md
```markdown
# Directory Structure Analysis

## Top-Level Organization
[Tree diagram with annotations]

## Key Directories
| Directory | Purpose | Key Files |
|-----------|---------|-----------|
| /src | Source code | [list] |

## File Naming Conventions
- Components: [pattern]
- Tests: [pattern]
- Configs: [pattern]

## Module Boundaries
[What belongs where]
```

#### 3. CONVENTIONS.md
```markdown
# Coding Conventions Analysis

## Naming Conventions
| Type | Convention | Example |
|------|------------|---------|
| Variables | camelCase | userName |
| Components | PascalCase | UserProfile |

## Code Style
- Indentation: [tabs/spaces, size]
- Quotes: [single/double]
- Semicolons: [yes/no]

## Patterns Used
- Error handling: [pattern]
- Async operations: [pattern]
- State updates: [pattern]

## Anti-Patterns Found
- [Anti-pattern]: [location] - [recommendation]
```

#### 4. TESTING.md
```markdown
# Testing Analysis

## Test Coverage
- Unit: [X%]
- Integration: [X%]
- E2E: [X%]

## Testing Frameworks
| Framework | Purpose | Config File |
|-----------|---------|-------------|
| [framework] | [purpose] | [file] |

## Test Patterns
- Mocking: [approach]
- Fixtures: [location]
- Setup/Teardown: [pattern]

## Coverage Gaps
- [Area with low coverage]: [risk level]
```

#### 5. INTEGRATIONS.md
```markdown
# External Integrations Analysis

## APIs
| API | Purpose | Auth Method | Files |
|-----|---------|-------------|-------|
| [api] | [purpose] | [auth] | [files] |

## Databases
| DB | Type | Connection | Models |
|----|------|------------|--------|
| [db] | [type] | [file] | [models] |

## Third-Party Services
- [Service]: [purpose, config location]

## Internal Services
- [Service]: [purpose, communication method]
```

#### 6. TECH-DEBT.md
```markdown
# Technical Debt Analysis

## TODO/FIXME Comments
| File | Line | Comment | Priority |
|------|------|---------|----------|
| [file] | [line] | [comment] | [priority] |

## Deprecated Code
- [Code/pattern]: [location] - [replacement needed]

## Known Issues
- [Issue]: [impact] - [suggested fix]

## Upgrade Needed
| Dependency | Current | Latest | Breaking Changes |
|------------|---------|--------|------------------|
| [dep] | [ver] | [ver] | [yes/no] |

## Refactoring Opportunities
- [Area]: [benefit of refactoring]
```

#### 7. FRAGILE-AREAS.md
```markdown
# Fragile Areas Analysis

## High-Risk Files
| File | Risk Level | Reason | Recommendation |
|------|------------|--------|----------------|
| [file] | HIGH/MED/LOW | [reason] | [action] |

## Complex Coupling
[Files with high coupling that require careful changes]

## Change Hotspots
[Files changed most frequently - from git log]

## Missing Tests
[Critical paths without test coverage]

## Undocumented Behavior
[Code doing non-obvious things]

## Single Points of Failure
[Code that many other parts depend on]
```

### Parallel Execution

**IMPORTANT: All 7 analyses MUST run in parallel to minimize time.**

```
Use Task tool to spawn 7 parallel agents:

Task 1: "Analyze architecture patterns and generate ARCHITECTURE.md"
Task 2: "Analyze directory structure and generate STRUCTURE.md"
Task 3: "Analyze coding conventions and generate CONVENTIONS.md"
Task 4: "Analyze testing patterns and generate TESTING.md"
Task 5: "Analyze external integrations and generate INTEGRATIONS.md"
Task 6: "Analyze technical debt and generate TECH-DEBT.md"
Task 7: "Analyze fragile areas and generate FRAGILE-AREAS.md"
```

### Post-Analysis Synthesis

After all 7 parallel analyses complete:

1. **Create CODEBASE-OVERVIEW.md** - Synthesize key findings from all 7 files
2. **Generate change-risk-matrix** - Which areas are safe vs risky to modify
3. **Produce onboarding-guide** - How a new developer should approach this codebase
4. **Update BRD-tracker** - Note any constraints discovered for new feature development

---

## STANDARD ANALYSIS MODE

For quick codebase overview (non-brownfield), use the standard analysis below.

## Project Discovery Phase
### Directory Structure
!`find . -type d -not -path "./node_modules/*" -not -path "./.git/*" -not -path "./dist/*" -not -path "./build/*" -not -path "./.next/*" -not -path "./coverage/*" | sort`
### Complete File Tree
!`find . -type f -not -path "./node_modules/*" -not -path "./.git/*" -not -path "./dist/*" -not -path "./build/*" -not -path "./.next/*" -not -path "./coverage/*" -not -path "./*.log" | head -100`
### File Count and Size Analysis
- Total files: !`find . -type f -not -path "./node_modules/*" -not -path "./.git/*" | wc -l`
- Code files: !`find . -name "*.js" -o -name "*.ts" -o -name "*.jsx" -o -name "*.tsx" -o -name "*.py" -o -name "*.java" -o -name "*.php" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" -o -name "*.cpp" -o -name "*.c" | grep -v node_modules | wc -l`
- Project size: !`du -sh .`
## Configuration Files Analysis
### Package Management
- Package.json: @package.json
- Package-lock.json exists: !`ls package-lock.json 2>/dev/null || echo "Not found"`
- Yarn.lock exists: !`ls yarn.lock 2>/dev/null || echo "Not found"`
- Requirements.txt: @requirements.txt
- Gemfile: @Gemfile
- Cargo.toml: @Cargo.toml
- Go.mod: @go.mod
- Composer.json: @composer.json
### Build & Dev Tools
- Webpack config: @webpack.config.js
- Vite config: @vite.config.js
- Rollup config: @rollup.config.js
- Babel config: @.babelrc
- ESLint config: @.eslintrc.js
- Prettier config: @.prettierrc
- TypeScript config: @tsconfig.json
- Tailwind config: @tailwind.config.js
- Next.js config: @next.config.js
### Environment & Docker
- .env files: !`find . -name ".env*" -type f`
- Docker files: !`find . -name "Dockerfile*" -o -name "docker-compose*"`
- Kubernetes files: !`find . -name "*.yaml" -o -name "*.yml" | grep -E "(k8s|kubernetes|deployment|service)"`
### CI/CD Configuration
- GitHub Actions: !`find .github -name "*.yml" -o -name "*.yaml" 2>/dev/null || echo "No GitHub Actions"`
- GitLab CI: @.gitlab-ci.yml
- Travis CI: @.travis.yml
- Circle CI: @.circleci/config.yml
## Source Code Analysis
### Main Application Files
- Main entry points: !`find . -name "main.*" -o -name "index.*" -o -name "app.*" -o -name "server.*" | grep -v node_modules | head -10`
- Routes/Controllers: !`find . -path "*/routes/*" -o -path "*/controllers/*" -o -path "*/api/*" | grep -v node_modules | head -20`
- Models/Schemas: !`find . -path "*/models/*" -o -path "*/schemas/*" -o -path "*/entities/*" | grep -v node_modules | head -20`
- Components: !`find . -path "*/components/*" -o -path "*/views/*" -o -path "*/pages/*" | grep -v node_modules | head -20`
### Database & Storage
- Database configs: !`find . -name "*database*" -o -name "*db*" -o -name "*connection*" | grep -v node_modules | head -10`
- Migration files: !`find . -path "*/migrations/*" -o -path "*/migrate/*" | head -10`
- Seed files: !`find . -path "*/seeds/*" -o -path "*/seeders/*" | head -10`
### Testing Files
- Test files: !`find . -name "*test*" -o -name "*spec*" | grep -v node_modules | head -15`
- Test config: @jest.config.js
### API Documentation
- API docs: !`find . -name "*api*" -name "*.md" -o -name "swagger*" -o -name "openapi*" | head -10`
## Key Files Content Analysis
### Root Configuration Files
@README.md
@LICENSE
@.gitignore
### Main Application Entry Points
!`find . -name "index.js" -o -name "index.ts" -o -name "main.js" -o -name "main.ts" -o -name "app.js" -o -name "app.ts" -o -name "server.js" -o -name "server.ts" | grep -v node_modules | head -5`
## Your Task
Based on all the discovered information above, create a comprehensive analysis that includes:
## 1. Project Overview
- Project type (web app, API, library, etc.)
- Tech stack and frameworks
- Architecture pattern (MVC, microservices, etc.)
- Language(s) and versions
## 2. Detailed Directory Structure Analysis
For each major directory, explain:
- Purpose and role in the application
- Key files and their functions
- How it connects to other parts
## 3. File-by-File Breakdown
Organize by category:
- **Core Application Files**: Main entry points, routing, business logic
- **Configuration Files**: Build tools, environment, deployment
- **Data Layer**: Models, database connections, migrations
- **Frontend/UI**: Components, pages, styles, assets
- **Testing**: Test files, mocks, fixtures
- **Documentation**: README, API docs, guides
- **DevOps**: CI/CD, Docker, deployment scripts
## 4. API Endpoints Analysis
If applicable, document:
- All discovered endpoints and their methods
- Authentication/authorization patterns
- Request/response formats
- API versioning strategy
## 5. Architecture Deep Dive
Explain:
- Overall application architecture
- Data flow and request lifecycle
- Key design patterns used
- Dependencies between modules
## 6. Environment & Setup Analysis
Document:
- Required environment variables
- Installation and setup process
- Development workflow
- Production deployment strategy
## 7. Technology Stack Breakdown
List and explain:
- Runtime environment
- Frameworks and libraries
- Database technologies
- Build tools and bundlers
- Testing frameworks
- Deployment technologies
## 8. Visual Architecture Diagram
Create a comprehensive diagram showing:
- High-level system architecture
- Component relationships
- Data flow
- External integrations
- File structure hierarchy
Use ASCII art, mermaid syntax, or detailed text representation to show:
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Frontend    │───> │      API        │────>│    Database     │
│   (React/Vue)   │     │   (Node/Flask)  │     │ (Postgres/Mongo)│
└─────────────────┘     └─────────────────┘     └─────────────────┘
## 9. Key Insights & Recommendations
Provide:
- Code quality assessment
- Potential improvements
- Security considerations
- Performance optimization opportunities
- Maintainability suggestions
Think deeply about the codebase structure and provide comprehensive insights that would be valuable for new developers joining the project or for architectural decision-making.
At the end, write all of the output into a file called "codebase_analysis.md"

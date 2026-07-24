# Dashboard Setup Guide

## Prerequisites

- Node.js 18+
- The conductor plugin installed
- A project with `conductor-state.json` (created by `/conduct new`)

## Installation

The conductor dashboard is a separate Next.js project. It is NOT bundled with the plugin.

```bash
git clone <conductor-dashboard-repo-url>
cd conductor-dashboard
npm install
```

## Configuration

Set the project directory the dashboard should watch:

```bash
# Via environment variable
export CONDUCTOR_PROJECT_DIR=/path/to/your/project

# Or via .env.local
echo "CONDUCTOR_PROJECT_DIR=/path/to/your/project" >> .env.local
```

## Running

```bash
npm run dev
# Dashboard available at http://localhost:3001
```

## How It Works

1. **File Watcher**: Uses chokidar to watch `conductor-state.json` in the configured project directory
2. **Diff Engine**: Computes state diffs on each file change
3. **SSE Endpoint**: `/api/events` streams state changes to connected browsers
4. **UI Components**: React components render phase progress, task queue, verification gates, agent timeline

## Type Contract

The dashboard TypeScript types in `src/types/conductor.ts` must stay compatible with `conductor-state.schema.json` from the plugin. If the schema changes, regenerate types:

```bash
npm run generate-types
```

## Multi-Project Support

To watch multiple projects, set comma-separated paths:

```bash
CONDUCTOR_PROJECT_DIRS=/path/project1,/path/project2
```

The dashboard will show a project selector.

## Troubleshooting

- **No updates appearing**: Verify `conductor-state.json` exists in the watched directory
- **Type errors**: Regenerate types after schema changes
- **SSE disconnects**: Check browser console for connection errors; SSE auto-reconnects

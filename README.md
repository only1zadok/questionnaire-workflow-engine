# Multi-Agent Workflow Engine

This project automates security questionnaire workflows: parse a buyer
questionnaire, retrieve grounded evidence, draft cited answers, route uncertain
answers to human review, and export the completed file.

The build follows `ROADMAP.md` one slice at a time.

## Development

Install dependencies:

```bash
uv sync --dev
```

Run the current tooling:

```bash
make lint
make typecheck
make test
```

The API and worker entrypoints are introduced in later Phase 1 slices.

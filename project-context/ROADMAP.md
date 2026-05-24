# ROADMAP.md

> Multi-Agent Workflow Engine for Security Questionnaire Automation
> Solo build · 2–4 weeks intense · One slice at a time, in order.

---

## How to use this file

- Work top-to-bottom. Never skip ahead.
- Tell the AI: **"do slice X.Y"** — it follows the PLAN → BUILD → TEACH → QUIZ loop from `PROJECT.md`.
- Tick the box `[x]` only after you've answered the quiz correctly **and** appended to `LEARNED.md`.
- If a slice exposes a bad earlier decision, stop and fix it before moving on.
- Estimates are budgets, not targets. If a slice goes 2x over, that's a sign to stop and ask why — usually you skipped a concept earlier.

---

## Phase 1 — Foundations
**Goal:** a running skeleton you can poke at. No intelligence yet.
**Checkpoint:** `curl /upload` → job appears in Postgres → worker picks it up → status flips to `done`. No AI.

---

### [ ] Slice 1.1 — Repo, tooling, project structure
**Budget:** 2h
**What we build**
- `uv` for dependency management, `pyproject.toml` with pinned versions
- `ruff` (lint + format), `mypy --strict`, `pytest`, `pre-commit`
- Folder layout: `app/api`, `app/agents`, `app/retrieval`, `app/storage`, `app/workers`, `tests/`, `evals/`, `docs/`
- A `Makefile` or `justfile` with `lint`, `test`, `run`, `worker` targets

**Key engineering decisions**
- `uv` over `poetry`: ~10x faster, becoming the default in 2026
- `mypy --strict` from day 1: easier to enforce than to retrofit
- `src/`-style layout vs flat: src-style prevents import shadowing and forces you to install the package

**Concept to internalise**
Why strict typing from day 1 is cheaper than typing later. Why pre-commit catches bugs before they reach the diff.

**Files touched**
`pyproject.toml`, `.pre-commit-config.yaml`, `Makefile`, `app/__init__.py`, `README.md` (stub)

---

### [ ] Slice 1.2 — FastAPI skeleton + Postgres via SQLAlchemy 2.0 async
**Budget:** 3h
**What we build**
- FastAPI app with `/health`, `/upload` (stub), `/jobs/{id}` (stub)
- Async SQLAlchemy 2.0 session factory + dependency-injected session
- Alembic for migrations
- First migration: `jobs` table with `id`, `status`, `created_at`, `payload jsonb`

**Key engineering decisions**
- SQLAlchemy 2.0 async style (not 1.x): the future, much cleaner
- Pydantic models for request/response schemas; SQLAlchemy models for the DB. Keep them separate.
- Migrations from day 1 — even for a solo project. Resetting the DB is not a strategy.

**Concept to internalise**
What `Depends()` actually does in FastAPI. The difference between an ORM model and a Pydantic schema and why you don't conflate them.

**Files touched**
`app/api/main.py`, `app/api/routes/health.py`, `app/api/routes/jobs.py`, `app/storage/db.py`, `app/storage/models.py`, `alembic/`, `alembic.ini`

---

### [ ] Slice 1.3 — Docker Compose: api + postgres + redis
**Budget:** 2h
**What we build**
- `Dockerfile` for the app (multi-stage build, non-root user)
- `docker-compose.yml` with `api`, `postgres` (with pgvector image), `redis`
- Healthchecks on every service
- `.env.example` checked in; `.env` gitignored

**Key engineering decisions**
- Use the `pgvector/pgvector:pg16` image now — you'll need it in Phase 2. Avoid migrating later.
- Multi-stage Dockerfile: builder stage installs deps, runtime stage copies only what's needed
- Healthchecks so `depends_on: condition: service_healthy` actually works

**Concept to internalise**
Why your local dev environment must match production-ish containers. The difference between `EXPOSE`, `ports`, and `expose` in Compose.

**Files touched**
`Dockerfile`, `docker-compose.yml`, `.env.example`, `.dockerignore`

---

### [ ] Slice 1.4 — Arq worker + first end-to-end job
**Budget:** 3h
**What we build**
- Arq worker that connects to Redis
- `/upload` writes a `Job` row (status=`queued`), enqueues an Arq task with the job id
- Worker task: load job → sleep 2s → mark status=`done`
- `/jobs/{id}` returns current status

**Key engineering decisions**
- Arq over Celery: async-native, no separate broker setup beyond Redis, simple API
- Job state lives in Postgres (durable), not Redis (which is just the queue) — separation of queue from state
- API handlers stay thin — they validate and enqueue, nothing else

**Concept to internalise**
Why HTTP handlers must never do long work. The pattern: API enqueues → Worker executes → Both touch the same DB row. This is the backbone of every real backend AI service.

**Files touched**
`app/workers/main.py`, `app/workers/tasks.py`, `app/api/routes/jobs.py` (real now), `docker-compose.yml` (add worker service)

---

**Phase 1 self-check (answer out loud before moving on):**
1. What happens when two requests hit `/upload` at the same time? Where could it race?
2. If the worker crashes mid-task, what state is the job left in? How would you fix that?

---

## Phase 2 — The Data Pipeline
**Goal:** working retrieval. Bad RAG → bad agents. Spend the time here.
**Checkpoint:** POST a question → get back the top 5 grounded chunks with sources. Eval harness gives you a `recall@5` number you can improve against.

---

### [ ] Slice 2.1 — Document ingestion (PDF, markdown, txt)
**Budget:** 3h
**What we build**
- `app/retrieval/loaders/` with one loader per format
- PDF via `pdfplumber` (text + page numbers)
- Markdown via a custom parser that preserves heading hierarchy
- Plain `.txt` for the trivial case
- `documents` table: `id`, `source`, `raw_text`, `extracted_text`, `metadata jsonb`, `ingested_at`
- CLI command: `python -m app.retrieval.ingest <path>`

**Key engineering decisions**
- Store both raw bytes AND extracted text. You'll want to re-parse with better tooling later.
- One loader interface, many implementations — Strategy pattern
- CLI for ingestion now; a `/documents` endpoint can come later if needed

**Concept to internalise**
PDF parsing is fundamentally unreliable. Build for failure: log what you couldn't extract, never silently skip pages.

**Files touched**
`app/retrieval/loaders/base.py`, `app/retrieval/loaders/pdf.py`, `app/retrieval/loaders/markdown.py`, `app/retrieval/ingest.py`, alembic migration for `documents`

---

### [ ] Slice 2.2 — Chunking strategy
**Budget:** 2h
**What we build**
- Recursive character splitter: 800 tokens, 100 overlap, splits on `\n\n` → `\n` → `. ` → ` `
- `chunks` table: `id`, `document_id`, `text`, `token_count`, `section_heading`, `page_number`, `metadata jsonb`
- Metadata propagation: each chunk knows its source document, page, and nearest preceding heading
- Test: ingest a SOC 2 sample report, verify chunks have correct metadata

**Key engineering decisions**
- Token-based, not character-based, chunking — `tiktoken` for the count
- 800/100 is a starting point, not gospel. You will tune this in Phase 2.5.
- Section headings as metadata — security docs are dense with them and they're free signal

**Concept to internalise**
Chunk size is a tradeoff: too small → lose context, too big → dilute relevance. Overlap exists to handle facts that straddle a boundary.

**Files touched**
`app/retrieval/chunking.py`, alembic migration for `chunks`

---

### [ ] Slice 2.3 — pgvector setup + embedding pipeline
**Budget:** 3h
**What we build**
- `CREATE EXTENSION vector` migration
- Add `embedding vector(1024)` column to `chunks` (1024 for voyage-3)
- HNSW index on the embedding column
- `app/retrieval/embeddings.py`: batched embedding via voyage-3 (or `text-embedding-3-large`)
- Worker task: embed all unembedded chunks in batches of 96
- Test: embed 100 chunks, query for nearest 5, verify they make sense

**Key engineering decisions**
- HNSW over IVFFlat: better recall at small-to-medium scale, no training step
- Batch embeddings — never one-at-a-time, it's 100x slower and more expensive
- The embedding model is a long-term commitment: changing it = re-embedding everything

**Concept to internalise**
How approximate nearest neighbour (ANN) actually works at a high level. The cosine vs dot-product vs L2 distance choice and why most embedding models normalise vectors so cosine == dot product.

**Files touched**
`app/retrieval/embeddings.py`, alembic migration for vector column + HNSW index

---

### [ ] Slice 2.4 — Hybrid search (BM25 + vector) + reranking
**Budget:** 4h
**What we build**
- BM25 via Postgres `tsvector` + `ts_rank_cd` on `chunks.text`
- Vector search via `embedding <=> query_embedding`
- Reciprocal Rank Fusion (RRF) to combine the two ranked lists
- Cohere `rerank-3` (or Voyage `rerank-2`) over the top 20 → return top 5
- `app/retrieval/search.py` with one `hybrid_search(query, k)` function

**Key engineering decisions**
- Hybrid > pure vector: keyword search catches exact terms (control IDs, acronyms) that embeddings miss
- RRF over score-normalisation: parameter-free, robust to scale differences
- Reranker is the single highest-impact addition. ~10–20% accuracy lift for ~$0.001/query.

**Concept to internalise**
Embeddings are bad at proper nouns and rare terms. BM25 is bad at synonyms. They fail in complementary ways — that's why hybrid wins. RRF math: `score = Σ 1/(k + rank_i)`.

**Files touched**
`app/retrieval/search.py`, alembic migration for `tsvector` column + GIN index

---

### [ ] Slice 2.5 — Retrieval evaluation harness
**Budget:** 4h (includes writing the golden set)
**What we build**
- 50 question/expected-chunk pairs hand-graded against your knowledge base. Use Oracle's CAIQ v4 PDF and write 50 realistic questions where you've manually identified the answering section.
- `evals/golden_set.jsonl` with `{question, expected_chunk_ids: [...], notes}`
- `evals/run_retrieval.py`: runs `hybrid_search` on each question, computes recall@5 and MRR
- Results written to `evals/results/<timestamp>.json`
- Diff script: compare two result files, show which questions got worse

**Key engineering decisions**
- 50 questions is the floor. Smaller and the metrics are noise; larger and you'll never write them.
- Evaluate retrieval **separately** from generation. If retrieval is broken, no LLM can save you.
- Store results as JSON, not in the DB — `git diff` over eval results is your version-controlled progress.

**Concept to internalise**
You cannot improve what you don't measure. The eval set is the most valuable artifact in the whole project — guard it. Recall@5 is "did the right chunk appear in the top 5"; MRR rewards getting it higher.

**Files touched**
`evals/golden_set.jsonl`, `evals/run_retrieval.py`, `evals/diff.py`, `evals/README.md`

---

**Phase 2 self-check:**
1. Your recall@5 is 0.6. Where would you look first — chunking, embeddings, or hybrid weighting?
2. A question contains the acronym "MFA". Pure vector search returns nothing. Why, and what fixes it?

---

## Phase 3 — The Agents
**Goal:** the multi-agent graph that actually fills the questionnaire.
**Checkpoint:** upload a 30-question xlsx → 30 answered, cited, confidence-scored rows back.

---

### [ ] Slice 3.1 — LangGraph: state + parser node
**Budget:** 3h
**What we build**
- Pin `langgraph` to an exact version in `pyproject.toml`
- `app/agents/state.py`: `JobState` and `QuestionState` as Pydantic models (typed `Literal` for status fields)
- `app/agents/nodes/parser.py`: xlsx → `list[QuestionState]`. Use `openpyxl`. Detect the question column deterministically (look for headers like "Question", "Control", "Inquiry"); fall back to LLM only on failure.
- Wire into the worker: job picks up file → parser node → writes questions to DB
- Test: parse a fake 10-row xlsx, verify all rows become `QuestionState` objects

**Key engineering decisions**
- The State is the contract. Spend an hour designing it before any code.
- Deterministic parsing first, LLM as fallback — the cheapest tool that works
- Persist parsed questions to DB immediately so re-runs don't re-parse

**Concept to internalise**
"Agents" are functions over state. Demystify the term — there's no magic, just typed I/O.

**Files touched**
`app/agents/state.py`, `app/agents/nodes/parser.py`, alembic migration for `questions` table

---

### [ ] Slice 3.2 — Retriever node
**Budget:** 2h
**What we build**
- `app/agents/nodes/retriever.py`: wraps `hybrid_search` from Slice 2.4
- Writes `retrieved_chunks: list[Chunk]` into `QuestionState`
- Per-question logging: question id, top 5 chunk ids, retrieval latency

**Key engineering decisions**
- The agent is a thin wrapper over Phase 2 — don't re-implement search
- Log enough to debug a single question's retrieval from production traces

**Concept to internalise**
Composability. You spent 4 days on retrieval; the agent reuses it in 30 lines.

**Files touched**
`app/agents/nodes/retriever.py`

---

### [ ] Slice 3.3 — Drafter node + structured output
**Budget:** 4h
**What we build**
- `app/agents/nodes/drafter.py`: takes `QuestionState` with chunks, returns draft answer + citations
- Use `instructor` library (or Anthropic tool use) for guaranteed JSON output
- Output schema: `{answer: str, response_type: Literal["yes", "no", "n/a", "explain"], citations: list[CitationRef]}`
- Each `CitationRef` has `chunk_id` and `snippet` — making citations machine-checkable
- Model: Claude Sonnet 4.6, temperature 0.2

**Key engineering decisions**
- Structured output via schema is non-negotiable — free-text answers break everything downstream
- Citations must reference chunk IDs that the retriever returned. Validate this in code.
- Low temperature for drafter: we want consistency, not creativity

**Concept to internalise**
The difference between "the model said it cited X" and "X is verifiably in the prompt". Schema-constrained decoding turns the second into a free guarantee.

**Files touched**
`app/agents/nodes/drafter.py`, `app/agents/schemas.py`

---

### [ ] Slice 3.4 — Critic node + the draft/critique pattern
**Budget:** 3h
**What we build**
- `app/agents/nodes/critic.py`: input is `{question, draft_answer, citations, retrieved_chunks}`
- Output schema: `{confidence: float (0-1), issues: list[str], faithfulness_ok: bool, suggested_revision: str | None}`
- Different system prompt to drafter — focused only on "does this answer match this evidence?"
- Model: Sonnet 4.6 at temperature 0.0, separate prompt file

**Key engineering decisions**
- Separation of concerns: drafter generates, critic verifies. Same model, different jobs, different prompts.
- Temperature 0.0 on critic: we want determinism in the verifier
- The critic doesn't have access to your knowledge base — only the evidence already retrieved. This is deliberate: it judges whether the answer is supported by what was retrieved, not whether the answer is "true in general".

**Concept to internalise**
Why LLM-as-judge is more reliable than LLM-as-author for the same task. Verification is easier than generation. This pattern shows up everywhere in production AI — internalise it.

**Files touched**
`app/agents/nodes/critic.py`, `app/agents/prompts/critic.txt`

---

### [ ] Slice 3.5 — Router + conditional edges in LangGraph
**Budget:** 3h
**What we build**
- `app/agents/nodes/router.py`: pure logic, no LLM
- Rules: confidence < 0.7 → `needs_review`; category in `HIGH_RISK_CATEGORIES` → `needs_review`; else → `auto_approved`
- `HIGH_RISK_CATEGORIES` lives in config: `["data_handling", "encryption", "incident_response", "subprocessors"]`
- Build the LangGraph: parser → retriever → drafter → critic → router → END
- Conditional edge from router that doesn't change graph flow but tags the final state

**Key engineering decisions**
- Rules over LLMs where you can — cheaper, faster, deterministic, testable
- Threshold lives in config, not hardcoded. You will tune it.
- Router writes the final status to DB; the human review UI reads from there

**Concept to internalise**
Conditional graph edges in LangGraph. The mental model of an agent system as a finite state machine. When you'd reach for a rule vs an LLM.

**Files touched**
`app/agents/nodes/router.py`, `app/agents/graph.py` (the StateGraph definition), `app/config.py`

---

### [ ] Slice 3.6 — End-to-end eval
**Budget:** 5h (includes grading 30 answers by hand)
**What we build**
- Take 30 CAIQ questions, write the ideal answer by hand, store as `evals/qa_golden_set.jsonl`
- `evals/run_qa.py`: runs the full graph on each question, scores answers
- Metrics: answer accuracy (manual or LLM-judged), citation faithfulness, % needing review, $ per question, latency p50/p95
- Ragas integration for `faithfulness` and `answer_relevance` metrics
- Results dashboard: a single markdown file `evals/results/<timestamp>.md` with all numbers

**Key engineering decisions**
- Hand-grade the answers — Ragas is good but a human eye finds different bugs
- Track cost per question from day 1 — it's a real interview question
- Latency matters: a 60-second-per-question system can't process a 261-question CAIQ in reasonable time

**Concept to internalise**
End-to-end evals catch issues that component evals miss. The drafter might be perfect and the critic might be perfect and the whole system might still produce bad answers because of how they interact.

**Files touched**
`evals/qa_golden_set.jsonl`, `evals/run_qa.py`, `evals/results/`

---

**Phase 3 self-check:**
1. Walk through what happens to one question, end-to-end, naming every node and what it adds to state.
2. Your critic says confidence 0.9 but the answer is wrong. Where do you look first?

---

## Phase 4 — Production polish
**Goal:** the things that make it look like a real engineer built it, not a tutorial follower.
**Checkpoint:** a stranger can hit your live URL, upload a questionnaire, review flagged answers, and download the result.

---

### [ ] Slice 4.1 — Human-in-the-loop review UI
**Budget:** 6h (UI eats time — cap it)
**What we build**
- `/jobs/{id}/review`: list of `needs_review` answers with question, draft, citations, confidence, issues
- Per-answer actions: Approve / Edit / Reject
- Approve → status = `human_approved`. Edit → save new text + status = `human_approved`. Reject → status = `rejected`, optional re-route back through drafter with notes.
- UI: HTMX + Jinja2 templates. Vanilla CSS. No build step.

**Key engineering decisions**
- HTMX is a deliberate choice — ships in a day, looks fine, no React build pipeline. The backend is the demonstration.
- LangGraph's `interrupt` primitive for resume-after-human — read its docs carefully
- Reviewer actions are append-only events on an `audit_log` table, not destructive updates

**Concept to internalise**
Human-in-the-loop is not a feature, it's a primitive. The graph pauses, waits for input, resumes. This is what production AI systems look like — fully-autonomous is mostly a demo.

**Files touched**
`app/api/routes/review.py`, `app/templates/review.html`, `app/templates/components/answer_card.html`, `static/style.css`

---

### [ ] Slice 4.2 — Observability
**Budget:** 3h
**What we build**
- LangSmith integration (free tier) — every LLM call and graph traversal traced
- `structlog` for application logs with bound context (`job_id`, `question_id`, `request_id`)
- Request ID middleware in FastAPI; the worker propagates it to logs
- `/metrics` endpoint with counts of jobs by status, p50/p95 latency, recent errors

**Key engineering decisions**
- LangSmith over rolling-your-own: you need the LLM-specific UI for debugging agent loops
- Structured logging from day 1 — JSON logs, no string concatenation
- Correlation IDs are the difference between "I can debug this" and "good luck"

**Concept to internalise**
Distributed tracing concepts: traces, spans, attributes, parent/child. Even in a small system, the pattern is the same as Datadog/Honeycomb in production.

**Files touched**
`app/observability/logging.py`, `app/observability/tracing.py`, `app/api/middleware.py`, `app/api/routes/metrics.py`

---

### [ ] Slice 4.3 — Cost + token tracking
**Budget:** 2h
**What we build**
- `llm_calls` table: `id`, `job_id`, `question_id`, `node` (drafter/critic/parser), `model`, `tokens_in`, `tokens_out`, `usd_cost`, `latency_ms`, `created_at`
- Wrapper around the Anthropic client that records every call
- `/jobs/{id}/cost` returns total $ and per-node breakdown
- A startup-time sanity check that bails if the wrapper isn't applied

**Key engineering decisions**
- Cost tracking is non-negotiable in production AI. Anyone who's run a real system has been burned by a runaway loop.
- Wrap at the client layer, not per-call site — exactly once means it can't be missed
- Store cost in USD as a `numeric(10, 6)` — float arithmetic on money is unforgivable

**Concept to internalise**
Cost telemetry is observability. You should be able to point at any job and say "this cost $0.34, here's why."

**Files touched**
`app/llm/client.py` (the wrapper), alembic migration for `llm_calls`, `app/api/routes/jobs.py` (add cost endpoint)

---

### [ ] Slice 4.4 — Export back to xlsx
**Budget:** 3h
**What we build**
- Endpoint `/jobs/{id}/export` returns the original xlsx with answers and citations filled in
- `openpyxl` preserves original formatting; write answers into the rows where questions came from
- New column: "Confidence" (auto-approved / human-approved / needs-review)
- New column: "Citations" with hyperlinks back to source documents
- Test: round-trip a CAIQ xlsx — upload, process, download, diff against expected

**Key engineering decisions**
- Round-tripping user data is the unsexy 30% of every real system. Get it right.
- Don't generate a new xlsx — modify a copy of the original. Buyers care about formatting they recognise.
- Cell-level audit: each filled cell gets a comment with the timestamp and reviewer

**Concept to internalise**
The "boring" data plumbing is half the actual job. The agentic stuff is the showy 50%; this is the half that ships.

**Files touched**
`app/api/routes/export.py`, `app/export/xlsx_writer.py`

---

### [ ] Slice 4.5 — Deploy + README + recorded demo
**Budget:** 5h
**What we build**
- Fly.io app, Postgres via Fly's managed offering, Upstash Redis (free tier)
- `fly.toml` with two processes: `api` and `worker`
- Secrets via `fly secrets set`
- README with: architecture diagram (Mermaid), eval numbers, quickstart, demo URL
- 90-second Loom: upload a real CAIQ → watch jobs progress → review 2 flagged → download result. Talk over it.

**Key engineering decisions**
- Live demo URL > a great README. Recruiters click links.
- Mermaid diagram in README — renders in GitHub natively
- The Loom is your interview pre-screen. Treat it that way.

**Concept to internalise**
A project that recruiters skim in 30 seconds vs one they don't. The README is the project; the code is what backs it up.

**Files touched**
`fly.toml`, `README.md`, `docs/ARCHITECTURE.md`, `.github/workflows/ci.yml` (lint + test on push)

---

**Phase 4 self-check:**
1. A friend uploads a malformed xlsx. Walk through every layer it hits and where it should fail safely.
2. Your cost-per-question is $0.18 and a CAIQ has 261 questions. That's $47 a run. What are your three levers to reduce it without losing accuracy?

---

## Stretch slices (only if you're ahead of schedule)

### [ ] S.1 — Answer caching
Deduplicate identical questions across questionnaires. SHA the normalised question text; if cached and the knowledge base hasn't changed, return the cached answer.

### [ ] S.2 — Model routing
Cheap model (Haiku 4.5) for high-confidence-by-category questions; Sonnet only for ambiguous ones. Cuts cost 40–60% in practice.

### [ ] S.3 — Query rewriting
Before retrieval, rewrite the question into 3 paraphrases via an LLM, search each, merge results via RRF. Improves recall on awkwardly-worded buyer questions.

### [ ] S.4 — Citation verification node
A sixth agent that opens each citation and checks whether the snippet actually supports the claim. Slower but cuts hallucinated citations to near zero.

---

## Done definition

This project is "done" when:
- [ ] All Phase 1–4 slices ticked
- [ ] `LEARNED.md` has at least 60 entries (3 per slice average)
- [ ] Live demo URL works for a stranger with no setup
- [ ] You can deliver the 60-second pitch from `PROJECT.md` section 8 without notes
- [ ] You can answer all five "hard questions" in section 8.2 to your own satisfaction
- [ ] One person who is not you has run the demo end-to-end and given you feedback

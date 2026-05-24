# PROJECT.md

> Multi-Agent Workflow Engine for Security Questionnaire Automation
> The single source of truth for what we're building and why.
> The AI in the IDE reads this file at the start of every session.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Domain](#2-problem-domain)
3. [Architecture Overview](#3-architecture-overview)
4. [Stack & Engineering Decisions](#4-stack--engineering-decisions)
5. [The State Model](#5-the-state-model)
6. [Data Flow: One Question End-to-End](#6-data-flow-one-question-end-to-end)
7. [Failure Modes & Mitigations](#7-failure-modes--mitigations)
8. [What's In Scope, What's Cut, and Why](#8-whats-in-scope-whats-cut-and-why)
9. [The Working Agreement](#9-the-working-agreement)
10. [The Interview Pitch](#10-the-interview-pitch)
11. [Glossary](#11-glossary)

---

## 1. Executive Summary

We are building a multi-agent system that ingests a security questionnaire (CAIQ, SIG, or a custom buyer spreadsheet), parses it into structured questions, retrieves grounded evidence from a knowledge base of the company's security documentation, drafts cited answers per question, routes low-confidence answers to a human reviewer, and exports the completed questionnaire back to the buyer's original format.

### 1.1 Why this project exists

This is a real industry problem with real money behind it. Enterprise security teams spend 20–40 hours per questionnaire and face 500+ per year at scale. The market is being captured right now by Vanta, V7 Go, SecurityScorecard, Anecdotes, Iris, and Tribble — all of them shipping exactly this class of system. We are not cloning their product. We are building the engineering core that proves the builder can design and ship the same class of system.

### 1.2 Why this project specifically gets the builder hired

A single repo that demonstrates, with evidence:

- Typed async Python backend (FastAPI, SQLAlchemy 2.0, Pydantic)
- Stateful multi-agent orchestration (LangGraph)
- Production RAG (hybrid search, reranking, evaluation)
- Queue-based job processing (Arq + Redis)
- Postgres + pgvector for unified persistence
- Observability and cost tracking (LangSmith, structlog)
- Human-in-the-loop primitives
- A measurable eval harness with golden sets and tracked metrics
- A live demo URL

Every one of those is a Backend + AI Engineer interview signal. The project is one coherent system, not a portfolio of disconnected toys.

### 1.3 What "done" looks like in 4 weeks

- FastAPI service accepts an uploaded questionnaire (xlsx or PDF) and a knowledge base of security documents
- LangGraph orchestrates five agents: Parser → Retriever → Drafter → Critic → Router
- PostgreSQL for persistent state, pgvector for embeddings, Redis for queueing
- HTMX or Next.js review UI where the human approves, edits, or rejects flagged answers
- LangSmith traces + cost tracking per question
- Deterministic eval harness with at least 50 golden retrieval questions and 30 graded answers
- Demo: upload the public Oracle CAIQ v4 PDF, watch the system fill it in, review 10 flagged answers, download the completed xlsx
- Live URL on Fly.io and a 90-second Loom walkthrough

### 1.4 What the builder should be able to explain on the other side

- Why a multi-agent architecture beats a single big prompt — and when it doesn't
- Why orchestrator-worker beats agent-to-agent handoff for this problem
- How RAG fails in production and how each failure mode was mitigated
- Why typed state graphs beat chained function calls
- How to 10x throughput, where the bottleneck is, and what it would cost
- How to reduce cost per question without losing answer quality

---

## 2. Problem Domain

Before writing a line of code, understand the problem. Skip this and the wrong abstractions get baked in.

### 2.1 The real-world workflow

A buyer (large enterprise) wants to assess a vendor (a SaaS company) before signing a contract. The buyer sends a security questionnaire — a structured set of 100–400 questions covering data handling, encryption, incident response, access control, sub-processors, business continuity, and compliance certifications.

The vendor's security or sales engineering team must answer each question, cite evidence (SOC 2 report sections, policy documents, control IDs), and return the completed questionnaire. The same questions get asked across buyers, but each buyer uses a slightly different format. The vendor has all the answers somewhere — in PDFs, Confluence, Notion, prior responses. Finding and re-assembling them is the work.

### 2.2 The questionnaire formats

| Format | Size | What it covers | Source |
|---|---|---|---|
| **CAIQ v4** | 261 questions | Cloud Security Alliance. Yes/No + explanation. Maps to 17 CCM control families. Public template. | Free download from CSA |
| **CAIQ Lite** | 124 questions | Condensed CAIQ for quick screening. | Free |
| **SIG Core** | ~1000 questions | Shared Assessments. Maps to 35+ regulatory frameworks. Broader than CAIQ (privacy, ops, resilience). | Paid template |
| **SIG Lite** | ~125 questions | Top-level SIG for initial vendor screening. | Paid |
| **Custom** | Variable | Buyer's own spreadsheet. Same domains, idiosyncratic wording, weird formats. | Per-buyer |

**Scope decision for this project:** support CAIQ v4 (PDF) and a generic xlsx with a "Question" column. That is sufficient to demonstrate every engineering pattern. Do not chase format coverage — chase depth on two formats.

### 2.3 Why this problem is engineering-hard

- **Question matching is non-trivial.** "Do you encrypt data at rest?" and "Is customer data encrypted when stored?" are the same question. Naive keyword matching fails. Pure semantic similarity gets confused by negations ("do you NOT log PII").
- **Evidence is scattered across format types.** SOC 2 reports are PDFs with tables. Policies are markdown. Prior questionnaires are xlsx. Each format has different parsing failure modes.
- **Wrong answers are expensive.** Hallucinating a control the company doesn't have can void contracts or mislead a buyer into trusting unsafe practices. This is the canonical "high-stakes RAG" problem.
- **Confidence matters more than the answer.** The system must know when it is unsure and escalate. A 95% confident wrong answer is a disaster; a 60% confident answer flagged for human review is the product.

These four properties are why a multi-agent architecture wins over a single LLM call. A single call cannot reliably do retrieval, drafting, self-criticism, and routing in one shot.

---

## 3. Architecture Overview

### 3.1 System diagram

```
  ┌─────────────┐
  │   Client    │  (Next.js UI, HTMX page, or curl)
  └──────┬──────┘
         │ HTTP
         ▼
  ┌───────────────────────────┐
  │   FastAPI service         │  stateless API layer
  │   /upload, /jobs, /review │
  └──────┬────────────────────┘
         │  enqueue job
         ▼
  ┌──────────────┐     ┌──────────────────┐
  │  Redis queue │ ──▶ │   Arq Worker     │
  └──────────────┘     │  (one per box)   │
                       └──────┬───────────┘
                              │
                              ▼
        ┌──────────────────────────────────────────┐
        │     LangGraph orchestrator               │
        │                                          │
        │   parser ──▶ retriever ──▶ drafter ──▶  │
        │                              │           │
        │                              ▼           │
        │                           critic         │
        │                              │           │
        │                              ▼           │
        │                           router ──▶ HIL │
        └────────────────┬─────────────────────────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
       ┌─────────────┐       ┌─────────────┐
       │ PostgreSQL  │       │  pgvector   │
       │ - jobs      │       │ - chunks    │
       │ - questions │       │ - embeddings│
       │ - answers   │       └─────────────┘
       │ - audit_log │
       │ - llm_calls │
       └─────────────┘
```

### 3.2 The five agents

#### Parser agent

Takes the uploaded questionnaire (xlsx or PDF) and produces a structured `list[Question]`: `{id, text, category, response_type, original_row}`. Uses `openpyxl` or `pdfplumber` depending on format. The agent uses an LLM **only when the format is ambiguous** — for example, when the question column header isn't standard. Otherwise it's deterministic code.

**Engineering principle here:** the parser is mostly deterministic with an LLM as fallback. Don't use an LLM for things deterministic code can do reliably. This is one of the most important habits of a senior engineer: picking the cheapest tool that works.

#### Retriever agent

For each question, retrieves the top-k relevant evidence chunks from the knowledge base using **hybrid search**: BM25 keyword search + dense embedding search, fused via Reciprocal Rank Fusion, then reranked with Cohere `rerank-3` or Voyage `rerank-2`. Returns chunks with source metadata (document name, page number, section heading).

#### Drafter agent

Given a question and its retrieved evidence, produces a candidate answer in the buyer's required format (yes/no + explanation for CAIQ, free text for SIG, etc.), with inline citations to specific evidence chunks. This is where most of the LLM cost lives. Uses Claude Sonnet 4.6 at low temperature, with structured output (Pydantic schema via `instructor` or Anthropic tool use).

#### Critic agent

Reviews the drafted answer against the evidence and outputs `{confidence: float, issues: list[str], faithfulness_ok: bool, suggested_revision: str | None}`. **This is the architectural secret.** A single-pass LLM hallucinates around 20–30% of citations in practice. A draft-then-critique pattern with separate prompts and a verification-focused critic catches the majority of those hallucinations, because the critic is solving an easier problem (does this answer match this evidence?) than the drafter (find and synthesise the answer).

**Engineering principle here:** drafter and critic must use different prompts and different temperatures (drafter 0.2, critic 0.0). If they're identical, you're paying twice for the same blind spot. This is "LLM-as-judge with separation of concerns" — verification is easier than generation, exploit that.

#### Router agent

Based on critic confidence and rules (e.g. "all answers in the Encryption category require human review regardless of confidence"), routes each answer to `auto_approved` or `needs_review`. Writes to PostgreSQL and emits an event. **No LLM call here — pure logic.** Threshold lives in config and gets tuned against the eval set.

### 3.3 Why these five and not more or fewer

Each agent earns its place by solving a distinct sub-problem that the others can't solve well:

- Parser → structural transformation (file format → typed objects)
- Retriever → information retrieval (question → grounded evidence)
- Drafter → generation (evidence → cited answer)
- Critic → verification (answer + evidence → confidence)
- Router → policy (confidence + rules → routing decision)

Adding a sixth agent doubles debug surface for marginal lift. Removing any one collapses a distinct responsibility into another and degrades both. This is a deliberate, defensible architecture — that matters in interviews.

---

## 4. Stack & Engineering Decisions

Every choice below has a reason. The builder should be able to defend each one without the document open.

| Layer | Choice | Why this, not the alternative |
|---|---|---|
| **Language** | Python 3.11+ | Every AI library is Python-first. Async support has matured. The hireable market for AI/Python is far larger than AI/Go or AI/TS. |
| **API framework** | FastAPI | Async-native, Pydantic-integrated, OpenAPI auto-generated. Flask/Django are heavier and not async-first. Industry default for new Python AI services in 2026. |
| **Orchestration** | LangGraph | Typed state graphs, built-in checkpointing, human-in-the-loop primitive, conditional routing. CrewAI is easier but lacks checkpointing. AutoGen is heavier and conversation-centric. LangGraph is the production standard in 2026. |
| **LLM** | Claude Sonnet 4.6 + Haiku 4.5 | Sonnet for drafter/critic (reasoning matters). Haiku for parser/router (cheap, fast, deterministic enough). Picking models by job is a senior habit. |
| **DB** | PostgreSQL + pgvector | One database, not two. pgvector is production-grade in 2026. Avoids the Pinecone/Weaviate operational tax for a solo project. Demonstrates "knows when not to add infrastructure." |
| **Queue** | Redis + Arq | Arq is async-native, way lighter than Celery. Redis is needed anyway. Celery is enterprise-overkill for solo and uses sync workers — incompatible with the rest of the async stack. |
| **Embeddings** | voyage-3 (1024d) or OpenAI text-embedding-3-large | Don't self-host embeddings for a solo project. Cost is trivial at this scale. voyage-3 leads on retrieval benchmarks in 2026. |
| **Reranker** | Cohere rerank-3 or Voyage rerank-2 | Hosted rerankers are dramatically better than naive top-k. This single addition typically lifts RAG accuracy 10–20%. |
| **Observability** | LangSmith (free tier) + structlog | Every LLM call, every retrieval, every retry must be inspectable. Without this, debugging agentic systems is impossible. |
| **Evals** | Custom harness + Ragas | A custom golden-set runner gives full control. Ragas provides faithfulness / answer-relevance / context-precision for free. |
| **UI** | HTMX + Jinja2 (default) or Next.js | If the builder knows React well, Next.js. Otherwise HTMX ships in a day, looks fine, no build step. Backend is the demonstration; don't burn a week on UI. |
| **Deploy** | Fly.io + managed Postgres + Upstash Redis | Hiring managers want to click a URL. Fly.io is the cheapest path to a live demo with a real Postgres add-on. |

### 4.1 Things that look like good ideas and aren't (for this scope)

- **Pinecone / Weaviate / Qdrant.** Operational overhead for a solo project. pgvector is enough.
- **LangChain (the chains library).** Use `langgraph` directly. LangChain abstractions add indirection without value here.
- **Self-hosted embeddings.** A week of yak-shaving for negligible cost saving.
- **Provider abstraction (LiteLLM, etc.).** Interview-impressive but week-eating. Pin to Anthropic, stay focused.
- **Fine-tuning.** RAG plus good prompts is more than enough for this use case. Fine-tuning here is a bad-faith demo signal.
- **Multi-tenancy.** Triples scope. One company's docs only.
- **Auth beyond a simple API key.** Don't build login flows. They're not the project.

---

## 5. The State Model

Every multi-agent system has a State. Ours is a typed Pydantic object that flows through the graph. Every node reads and writes to it. This is where most engineers get lost — they pass dicts around and lose track of what's where.

### 5.1 The QuestionState contract

```python
from typing import Literal
from pydantic import BaseModel

class Citation(BaseModel):
    chunk_id: str
    snippet: str  # the actual text being cited
    source_document: str
    page_number: int | None

class Chunk(BaseModel):
    id: str
    text: str
    source_document: str
    page_number: int | None
    section_heading: str | None
    retrieval_score: float

class AuditEvent(BaseModel):
    timestamp: datetime
    node: str  # "parser", "drafter", "critic", ...
    action: str
    detail: dict

class QuestionState(BaseModel):
    # Identity
    question_id: str
    question_text: str
    category: str | None
    response_type: Literal["yes_no", "yes_no_explain", "free_text"]

    # Retrieval
    retrieved_chunks: list[Chunk] = []

    # Drafting
    draft_answer: str | None = None
    citations: list[Citation] = []

    # Critique
    critic_confidence: float | None = None
    critic_issues: list[str] = []
    faithfulness_ok: bool | None = None

    # Final
    final_answer: str | None = None
    status: Literal[
        "pending", "retrieved", "drafted", "critiqued",
        "auto_approved", "needs_review",
        "human_approved", "rejected"
    ] = "pending"

    # Provenance
    audit_log: list[AuditEvent] = []
```

### 5.2 Why this is the contract

- **Typed Literal statuses** mean impossible states are impossible — you cannot mistype `"approved"` as `"approve"` without mypy failing.
- **Citations carry their snippet** so verification doesn't require a database lookup.
- **`audit_log` is append-only** — every node appends, no node mutates prior entries.
- **Optional fields default sensibly** — a `QuestionState` is constructible the moment a question is parsed, before any agent has touched it.

### 5.3 The JobState wrapper

```python
class JobState(BaseModel):
    job_id: str
    questionnaire_format: Literal["caiq_v4", "sig_lite", "custom_xlsx"]
    questions: list[QuestionState]
    knowledge_base_version: str  # hash of all ingested docs at ingest time
    total_cost_usd: float = 0.0
    started_at: datetime
    finished_at: datetime | None = None
```

The `knowledge_base_version` is a hash. If the same question is asked after the KB changes, the cached answer is invalidated. This is the foundation for the answer-caching stretch slice.

---

## 6. Data Flow: One Question End-to-End

Walk through this until it's automatic. In an interview, an engineer should be able to draw this from memory.

1. **Upload.** Client POSTs `/upload` with an xlsx file. FastAPI validates content-type and size (10 MB cap), writes the raw file to object storage (or a `files/` directory for local), creates a `jobs` row with status=`queued`, enqueues an Arq task with the job id, returns `{job_id}`.

2. **Worker picks up.** Arq worker pulls the job from Redis, loads the file, instantiates the LangGraph with the job's `JobState` as initial state, runs the graph.

3. **Parser node.** Reads the xlsx, finds the question column (deterministic header match, LLM fallback), emits one `QuestionState` per row. Persists all questions to DB. Sets each question's status to `pending`.

4. **For each question (parallel up to N=5):**
   - **Retriever** runs `hybrid_search(question_text, k=20)`, sends to reranker, keeps top 5, writes to `retrieved_chunks`. Status → `retrieved`.
   - **Drafter** sends `(question, chunks)` to Sonnet with structured output schema. Receives `{answer, response_type, citations}`. Validates that every `citation.chunk_id` is in `retrieved_chunks`. Writes to `draft_answer` + `citations`. Status → `drafted`. Logs token usage to `llm_calls`.
   - **Critic** sends `(question, draft_answer, citations, chunks)` to Sonnet at temp 0.0 with the verification prompt. Receives `{confidence, issues, faithfulness_ok, suggested_revision}`. Writes to critic fields. Status → `critiqued`. Logs token usage.
   - **Router** evaluates rules: `if confidence < 0.7 or category in HIGH_RISK_CATEGORIES → needs_review else auto_approved`. For `auto_approved`, copies `draft_answer` to `final_answer`. Status updated. Writes audit event.

5. **Job completion.** When all questions reach a terminal status (`auto_approved`, `needs_review`, `human_approved`, `rejected`), job status → `awaiting_review` if any need review, else `completed`. Worker updates `jobs.finished_at` and `total_cost_usd`.

6. **Human review.** User visits `/jobs/{id}/review`. Sees `needs_review` answers with question, draft, citations, confidence, issues. Approves / Edits / Rejects each one. Each action writes an audit event and updates status.

7. **Export.** Once all questions are terminal, user hits `/jobs/{id}/export`. The xlsx writer opens the original file, fills in answers and confidence + citation columns, returns the file.

Every step is traced. Every LLM call is logged with cost. Every state transition is in the audit log. **This is what production AI systems look like.** The clever multi-agent stuff is 40% of the work; the plumbing above is the other 60% and is what separates real engineers from tutorial followers.

---

## 7. Failure Modes & Mitigations

A senior engineer thinks about how the system breaks before it breaks. Here are the failure modes we expect and what we do about each.

### 7.1 Retrieval misses

**Failure.** The right chunk doesn't appear in the top 5.
**Causes.** Question uses different terminology from the source doc. Question contains an acronym the embedding model doesn't know. Source is in a PDF that parsed badly.
**Mitigations.**
- Hybrid search (BM25 catches acronyms; embeddings catch paraphrases)
- Reranker over a wider initial candidate set (top 20 → top 5)
- Eval set with adversarial paraphrases to catch regressions
- Stretch slice S.3: query rewriting (LLM generates 3 paraphrases, search each, fuse)

### 7.2 Drafter hallucinates a citation

**Failure.** Drafter cites `chunk_id_42` but `chunk_id_42` doesn't actually support the claim, or doesn't exist.
**Causes.** LLM under-grounded by long context; prompt unclear about citation format.
**Mitigations.**
- Schema-enforced output: every citation must reference a chunk_id that was retrieved (validated in code, request rejected and retried if not)
- Critic node specifically checks citation faithfulness
- Stretch slice S.4: a sixth agent that opens each citation and verifies the snippet supports the claim

### 7.3 Drafter writes confidently when evidence is thin

**Failure.** No chunk really answers the question, but the drafter writes a plausible-sounding answer anyway.
**Causes.** LLMs are trained to be helpful; they fill in gaps. Empty context is rarely empty enough.
**Mitigations.**
- Drafter prompt explicitly instructs "if the evidence does not support a confident answer, say so and set response_type to 'insufficient_evidence'"
- Critic catches this on the second pass — its prompt asks "is the evidence sufficient"
- Router treats `insufficient_evidence` as automatic `needs_review`

### 7.4 Critic agrees with the drafter

**Failure.** Critic gives high confidence on a wrong answer.
**Causes.** Same model, similar prompt patterns, shared blind spots.
**Mitigations.**
- Different temperature (drafter 0.2, critic 0.0)
- Critic prompt is structurally different: it doesn't see the drafting instructions, only the verification task
- Optional: critic uses a different model entirely (Sonnet drafts, Opus critiques) — left as a stretch
- Eval set catches systematic critic failures via faithfulness metrics

### 7.5 Runaway costs

**Failure.** A bug causes the graph to loop, or an agent calls in a tight retry, racking up $100+ on one job.
**Causes.** No per-job cost ceiling; no max-iteration guard on LangGraph nodes.
**Mitigations.**
- LangGraph `recursion_limit` set explicitly per graph
- Per-job cost ceiling enforced in the LLM client wrapper (`$10 max per job` raises an exception)
- Cost-tracking from Phase 4 Slice 4.3 — every call recorded, dashboards visible

### 7.6 Worker crashes mid-job

**Failure.** Worker dies between questions. The job sits in `running` forever.
**Causes.** OOM, container restart, deploy.
**Mitigations.**
- LangGraph checkpointing to Postgres — each node completion is durable
- Worker startup task scans for jobs in `running` whose `updated_at` is > 5 min stale and resumes from last checkpoint
- Jobs older than 1 hour with no progress get marked `failed`

### 7.7 Slow PDF parsing

**Failure.** A 200-page SOC 2 report takes 90 seconds to parse and blocks the ingestion worker.
**Mitigations.**
- Ingestion is its own job type, separate from questionnaire jobs
- Streaming PDF parser where possible (one page at a time)
- Page-level error handling — one bad page doesn't kill the whole document

### 7.8 Embedding model drift

**Failure.** voyage-3 deprecates, replacement has different vector dimensions, every chunk needs re-embedding.
**Mitigations.**
- Embedding model name + dimension stored as DB metadata per chunk
- Migration script template ready (not built, just sketched in `docs/migrations.md`)
- Pin embedding model version explicitly in code

---

## 8. What's In Scope, What's Cut, and Why

A senior engineer is defined as much by what they refuse to build as by what they build.

### 8.1 In scope (defended below)

- One company / one knowledge base (no multi-tenancy)
- CAIQ v4 (PDF) and generic xlsx (single Question column) — two formats deeply, not many shallowly
- Five agents — no more
- HTMX review UI (or simple Next.js if the builder is comfortable)
- 50+ retrieval golden questions, 30+ end-to-end golden answers
- Local Postgres + pgvector, Redis, Arq worker
- Deployed to Fly.io with a public URL
- LangSmith free tier for tracing
- Cost tracking to per-question precision

### 8.2 Cut (with reasons)

| Cut | Why |
|---|---|
| Multi-tenancy | Triples scope. Adds row-level security, tenant onboarding, per-tenant rate limits. Not worth it for the demo. |
| Auth beyond API key | Login flows aren't the engineering signal. A `X-API-Key` header is enough. |
| Multiple LLM providers | Provider abstraction is interview-impressive but week-eating. Pin to Anthropic. |
| Fine-tuning | RAG plus good prompts is more than enough. Fine-tuning would be performative. |
| Generating questionnaires (vs answering them) | Different product, different agents, no incremental learning. |
| OAuth into Confluence/Notion/Google Drive | Integration plumbing is unglamorous and steals from the agentic learning. |
| Real-time collaboration on review UI | Not needed. Single-reviewer is fine. |
| Mobile-responsive UI | Demo from a laptop. |
| i18n | English questionnaires only. |

### 8.3 Stretch (only if ahead of schedule, not before Phase 4 ends)

- **Answer caching** — SHA the normalised question, cache against KB version, return cached answers
- **Model routing** — Haiku for safe categories, Sonnet only for ambiguous ones (cuts cost 40–60%)
- **Query rewriting** — 3 paraphrases, RRF merge, lift recall on awkwardly-worded questions
- **Citation verification agent** — sixth agent opens each cited chunk and validates support
- **A second knowledge base type** — Confluence ingestion via API

---

## 9. The Working Agreement

This section governs how the builder and the AI work together. The AI re-reads this every session.

### 9.1 The loop, non-negotiable

Every slice follows this loop. No shortcuts.

1. **PLAN.** State in fewer than 8 bullets: what we'll build, which files, the 2–3 key engineering decisions, and what tradeoffs they involve. Wait for the builder's "go".

2. **BUILD.** Write the code. Small files. Type hints everywhere. No magic. Comments only where intent isn't obvious from the code.

3. **TEACH.** After the code, in under 300 words, explain:
   - Why this design over the alternative the builder would be tempted by as a junior
   - The tradeoff we accepted and what we lost
   - The single concept to internalise from this slice
   - Where this connects to earlier slices

4. **QUIZ.** Ask two questions. Not recall questions — questions that only make sense if the builder understood. If the builder gets one wrong, re-teach that point and re-quiz once.

### 9.2 Rules for the AI

- Never skip ahead in the roadmap
- Never refactor outside the current slice without flagging it first
- If the builder asks "why", give the real reason — not reassurance
- If a slice exposes a bad earlier decision, say so directly
- Update `STATE.md` after each finished slice
- Suggest 3 lines for `LEARNED.md` in the builder's voice (the builder edits before committing)
- If the builder asks for code without a plan, refuse and offer to plan first

### 9.3 Rules for the builder

- Read every file before running it
- Answer the quiz in your own words, not by copying from the explanation
- Append to `LEARNED.md` in your own words after every slice
- If you can't write the LEARNED entry, you didn't learn the slice — re-quiz
- Don't ask the AI to "just make it work" when something is broken — ask it to explain the error first
- One slice per session is the floor; two is fine; three is suspicious

### 9.4 The files and their roles

| File | Updated by | Purpose |
|---|---|---|
| `PROJECT.md` (this file) | Builder, rarely | Architecture, decisions, the "why". AI re-reads every session for context. |
| `ROADMAP.md` | Builder, ticks boxes | Ordered slices. AI consults to know what's next. |
| `STATE.md` | AI, after each slice | One-paragraph: current slice, blockers, open questions, next slice. Session continuity. |
| `LEARNED.md` | Builder writes, AI suggests | 3 lines per slice in the builder's own words. The learning artifact. AI reads to calibrate teaching depth. |

---

## 10. The Interview Pitch

By the end of week 4, this is rehearsed and tight.

### 10.1 The 60-second version

> "I built a multi-agent system that automates security questionnaires — the SIG and CAIQ forms enterprises send to vendors before signing contracts. The industry currently spends 20–40 hours per questionnaire. My system uses a LangGraph orchestration of five specialised agents — parser, retriever, drafter, critic, router — backed by hybrid search over a pgvector knowledge base, with human-in-the-loop review for low-confidence answers. I measured it on a 50-question golden set and got X% answer accuracy at $Y per question. The interesting engineering problem was separating draft from critique — a single LLM call hallucinated about 30% of citations, and a draft-then-verify pattern with separate prompts brought that under 5%."

### 10.2 The five hard questions an interviewer will ask

1. **Why LangGraph over CrewAI or AutoGen?** — Typed state, checkpointing, conditional routing. CrewAI lacks checkpointing for long jobs. AutoGen is conversation-centric and harder to reason about.

2. **How would you scale to 1000 concurrent questionnaires?** — Worker pool sizing per CPU and per LLM rate limit. Per-question batching. Embedding cache (questions get reused across buyers). Model routing by category (Haiku for safe, Sonnet for ambiguous). Postgres read replicas for retrieval. Move pgvector to a dedicated instance once it stops fitting.

3. **How do you know your answers are correct?** — Golden set, retrieval recall@5 and MRR measured separately from generation. Citation faithfulness via Ragas. Human review on confidence below threshold. The system is honest about uncertainty by design.

4. **What did you cut and why?** — Multi-tenancy, fine-tuning, complex UI, OAuth into KB sources, generating questionnaires. Backend is the demonstration; UI and integrations are commodities.

5. **Where does it break?** — Ambiguous yes/no questions where the right answer is "depends on context." Questions where the truthful answer is "we don't have that control" — the retriever returns adjacent-but-wrong context. Both are RAG failure modes I can articulate, not surprises.

### 10.3 What not to say in an interview

- "I followed a tutorial" — even if true, it makes the engineering decisions sound like accidents.
- "LangGraph just works" — name a specific tradeoff. Senior engineers don't talk in absolutes.
- "AI does the coding" — talk about the engineering decisions you made about what the AI built. The decisions are yours; the typing is divisible.

---

## 11. Glossary

Terms to know cold by the end of the project. If you can't define one, your `LEARNED.md` should have an entry for it.

- **ANN (Approximate Nearest Neighbour)** — search algorithms that trade exactness for speed when finding similar vectors. HNSW and IVFFlat are the two pgvector supports.
- **BM25** — a keyword-matching ranking function based on term frequency and inverse document frequency. The classical IR baseline.
- **CAIQ** — Consensus Assessments Initiative Questionnaire. CSA-maintained, 261 questions in v4.
- **CCM (Cloud Controls Matrix)** — CSA's 17 control families that CAIQ questions map to.
- **Chunk** — a passage of text small enough to embed and retrieve. Typically 500–1000 tokens with 50–150 overlap.
- **Embedding** — a fixed-length vector that represents the semantic content of text. Similar texts have similar vectors.
- **HNSW** — Hierarchical Navigable Small World. The graph-based ANN index used in pgvector. Better recall than IVFFlat at small-to-medium scale.
- **Hybrid search** — combining keyword (BM25) and semantic (embedding) search, usually fused via RRF.
- **LangGraph** — a Python library for building stateful multi-agent workflows as typed graphs. Built by the LangChain team.
- **MRR (Mean Reciprocal Rank)** — retrieval metric. If the right answer is at position 1, score = 1; at position 2, score = 1/2; etc. Averaged across queries.
- **Reciprocal Rank Fusion (RRF)** — score-free way to combine ranked lists. `score = sum(1 / (k + rank_i))`.
- **Recall@k** — retrieval metric. Fraction of queries for which the correct chunk appears in the top k results.
- **Reranker** — a model that re-orders an initial candidate list using cross-attention between query and each candidate. More accurate, more expensive than initial retrieval.
- **SIG** — Standardized Information Gathering questionnaire. Shared Assessments-maintained, ~1000 questions in Core.
- **SOC 2** — Service Organization Control 2. The audit report enterprises produce to demonstrate security controls. Comes in Type 1 (point-in-time) and Type 2 (over a period).
- **State graph** — a directed graph where nodes are functions over a shared typed state object. LangGraph's core abstraction.
- **Structured output** — making an LLM return JSON conforming to a schema, either via constrained decoding or via tool-use forcing.
- **Tool use** — Anthropic's mechanism for having the model call a typed function with a JSON-schema'd input. The basis for structured output.

---

*End of `PROJECT.md`. The AI should now read `ROADMAP.md`, `STATE.md`, and `LEARNED.md`, then confirm understanding in 3 sentences and wait.*

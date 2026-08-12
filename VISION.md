# VISION — what ukubi is becoming

**Status:** Direction, not specification. This file states the goal and the
rules that bound how it is pursued.

`ARCHITECTURE.md` is canonical for target specs, `DECISION.md` + `docs/adr/`
for decisions. This file sits above both and answers a different question:
*what is all of this for, and what is it converging toward.* Where this
disagrees with either on a concrete matter, they win — a vision does not
override a spec. Its job is to make the next decision obvious, not to
pre-empt it.

---

## The goal

**A home cloud that holds my entire technical plane, knows what it is meant
to be, and closes the distance on its own.**

Not a collection of projects that happen to share hardware — one organism,
owned end to end, in which my projects are organs sharing a bloodstream, and
the work that runs through them is cellular: short-lived, replaceable, dying
by design.

## The mental model

Biology, from macro to micro. Not decoration — the mapping is load-bearing,
and several rules below are taken directly from mechanisms that already
solve this problem under harsher penalties than ours.

| Biology | Here |
|---|---|
| Organism | `ukubi-cluster` — the whole, which persists |
| Organs | Projects/repos — differentiated function, shared bloodstream |
| Bloodstream | The substrate: git, registry, network, observability |
| Genome | Declared intent — `ARCHITECTURE.md` + `DECISION.md` |
| Gene expression | An agent acting on that intent, contextually |
| Cells | Tasks and worker pods — short-lived, interchangeable |
| Healing | Convergence of reality toward declared intent |
| Immune response | Drift detection — `mission-drift`, scheduled audits |
| Apoptosis | A worker terminating on failed self-verification |
| Cancer | An agent editing the genome, or growing unbounded |
| Germline change | A human-merged PR to declared intent |

## Principles

**1. The substrate is self-contained.** Source, images, builds, deployment
and observation live inside the cluster. External services are mirrors and
escape hatches, never links in the loop. The test: nothing the system does
routinely should terminate somewhere it cannot see.

**2. Declared intent is the source of truth.** `ARCHITECTURE.md` and
`DECISION.md` are not documentation *about* the system — they are the
specification it is measured against. Intent is authored; reality is
derived. When they disagree, reality is what is wrong, unless the
declaration is stale — which is a question to raise, not a defect to
silently correct.

**3. The gap is the work.** The difference between declared and actual is
computed continuously, and that difference *is* the backlog. Not a report
someone reads — a queue the system draws from.

**4. The genome is authored; expression is free.** Declared intent is
carried by every agent and modified by none. An agent may express it
contextually — differently in different positions — and may *propose* a
change to it as a PR with its reasoning, because reality teaches things the
spec did not know. It may never merge one. Spec change is germline: a
different mechanism, on a different timescale, human-selected.

**5. Repair is staged, checkpointed and locally bounded.** Contain before
correcting. Clear the broken thing before building on it. Land the
provisional version first and remodel toward the final one. Verify at every
boundary before an irreversible transition, and on failed verification
**arrest — never proceed on assumption.**

**Every intermediate state must be one I would be content to find.** Nothing
that is only correct once it finishes. If it stops halfway — on error, or
because I stopped it — what remains must be a valid resting state. This
rules out the entire class of "it will be consistent once the migration
completes", which is precisely where an unsupervised system does
irreversible damage while technically converging.

Scope stops at the edge of what the agent can directly verify. Bounded by
adjacency, like contact inhibition — not by a configured quota.

**6. Apoptosis over degradation.** An agent that cannot establish its own
correctness terminates instead of continuing. Death is cheap and normal; a
confused cell that keeps working is the expensive outcome.

**7. Rules are structural before they are asked.** A constraint should make
the bad state unrepresentable, or be detected automatically. Prose an agent
is trusted to comply with is the weakest form and the last resort. Three
tiers, and the discipline is moving rules *down* the list rather than adding
to it:

- **Structural** — the bad state cannot be represented, so nothing has to
  comply (`buildguard`; the LimitRange/pod-spec pin in `agent-fleet`).
- **Checked** — detected after the fact, cheaply and always (CI,
  `mission-drift`).
- **Asked** — genuine judgment, needs a human (`canUseTool`).

**8. Reversibility is the safety property, not restraint.** Every state the
system can reach is one it can be brought back from. That is what earns it
the freedom to act unsupervised, and it means the restore path must survive
the system failing entirely — so it cannot live only inside the cluster.

**9. It remembers.** Continuity across sessions, tasks and restarts is what
makes this an entity rather than a series of capable amnesiacs. The journal
is not a log; it is what persists when nothing else does.

**10. The relationship runs both ways.** It holds what I would forget,
notices what I would miss, and does the convergent work I would never get
to — and in return pursues only intent I authored. Symbiosis, not
automation: I remain the source of direction, it becomes the source of
follow-through.

## The frontier, stated honestly

Everything above describes a system that **converges**. It restores; it does
not originate. It will not propose a feature or notice an opportunity.

That is deliberate. It is the bounded, trustworthy half, and it should be
running and trusted before anything creative is contemplated.

Biology agrees, and for a better reason than caution: **no cell ever decides
to grow an organ.** Organogenesis follows morphogen gradients laid down
before the cells existed — the pattern comes from outside and before. Cells
execute it locally and magnificently, and never author it. Novelty in
biology comes from variation plus selection across generations: slow,
external to any individual, always retrospective.

Mapped over: the system may generate variants and propose them; a human
selects. Whether it ever gets to originate intent rather than pursue it is
the real open question, and it is not answered here.

## Where the metaphor breaks

Marked so it is not followed off a cliff.

Biology tolerates staggering waste — most neurons produced die, and that is
the design. We cannot be that casual with irreversible infrastructure
operations.

And biology has **no undo**. Healing is one-way, which is exactly why it
needs such conservative checkpoints. We have git. We are strictly better off
there, and should not import biology's caution where we have a real time
machine instead.

Take the biology for the *shape* of the rules — staged, checkpointed, local,
self-terminating. Use git and tests for the enforcement biology never had.

## What this implies next

Direction only; sequencing and feasibility belong in `DECISION.md` and
`docs/adr/` as each is actually taken.

- **Registry in-cluster before git.** Nearly pure upside: it removes the
  Docker Hub rate limit, makes per-repo images cheap, and losing it costs
  rebuilt images rather than lost work. Reversible, and it does not couple
  the ability to work to cluster uptime.
- **A restore path that leaves the failure domain, before autonomy.** Garage
  is in-cluster too; a backup story terminating there is not one (principle
  8).
- **Then git, mirrored.** Ownership is not sole custody — the mirror is the
  restore path, not a hedge against owning the stack. Note the bootstrap
  circularity: ArgoCD syncs `infra-bootstrap` from git, so the repos that
  bootstrap the cluster cannot be the ones hosted only inside it.
- **Give drift detection somewhere to write.** Turning `mission-drift` from
  prose into proposed tasks is the loop closing for the first time, still
  human-approved at the far end — and it reveals whether the drift signal is
  good enough to act on before anything acts on it unsupervised.

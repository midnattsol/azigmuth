# Wayfind — the azigmuth query language (v1, closed)

Wayfind is a frontier-pipeline query language over an azigmuth snapshot:
sets of node ids flow through a fixed sequence of steps. It is a topology
language by design — properties never appear in it; they live in caller
columns / DuckDB and compose with Wayfind through id sets and `prop_row`
join keys. *Wayfinding* is the craft of orienting and routing through
space; the azimuth is its instrument.

This document **closes v1**: the algebra, the textual grammar, the IR
encoding and the execution guarantees below are frozen. Extensions are
listed in §9 and may only be added under the stability rules in §8.

---

## 1. Why not Cypher (anti-decisions, normative)

| Decision | Rationale |
|---|---|
| No properties in the language | azigmuth stores topology only; value predicates belong to the columnar layer. Sets in, sets out. |
| Set semantics, no bags, no NULLs | matches the engine's frontiers; a node is in a set or it is not. |
| No query planner | reading order = execution order; cost is predictable from the text. |
| Read-only, one snapshot per query | consistency comes from the engine's RCU; mutation is the host API. |
| IR-first, comptime builder before parser | embedded targets pay zero parsing; the textual form is a thin front-end over the same IR. |

Declarative patterns (Cypher/GQL) rejected: they require a join optimizer.
Datalog rejected: semi-naïve evaluation is a heavy runtime; `*` closure
covers the dominant recursion. Gremlin's walk semantics rejected:
exponential by default; Wayfind keeps the pipeline shape with sets.

## 2. Data model

- **NodeSet** — the value that flows: a duplicate-free set of node ids
  (u32), always relative to the query's snapshot.
- **Snapshot anchoring** — a query executes against exactly one
  `CapturedGraphView` (or, in the future, a frozen mmap graph). Later
  mutations are invisible to a running query.
- **Liveness** — sets contain live nodes. Ids of removed nodes inside
  parameter sets are **silently dropped at bind time** (rationale: id sets
  computed against an older snapshot must remain usable after deletions;
  liveness is a property of the snapshot, not of the pipeline).
  Out-of-range ids (`>= nodeCount`) are a bind **error** (`InvalidNode`):
  they can never have been valid, so they signal a bug, not staleness.
- **Parameters** — `$name` denotes a caller-injected NodeSet (`[]const u32`
  / Arrow array). Duplicates in the input are deduplicated. Parameters are
  the composition ports to the analytics layer.
- **Relations** — edges carry a u16 relation. The textual form may use
  identifiers resolved through a caller-provided name→u16 map, or raw
  integers. `0xFFFF` is reserved: it means *any relation* and is not a
  valid edge relation value.

## 3. The algebra (closed set, v1)

A query is: **one source, zero or more transformations, one terminal.**

### 3.1 Sources (push one NodeSet)

| Text | Semantics |
|---|---|
| `from $s` | the bound parameter set (after liveness drop / dedup) |
| `from node:N` | singleton `{N}`; bind error if N is out of range or removed |
| `from *` | all live nodes of the snapshot |

### 3.2 Transformations (pop one, push one)

**`out(rel){m..n}`, `in(rel){m..n}`, `both(rel){m..n}`** — multi-hop
expansion. Precise semantics:

- Define `level(v)` = length of the shortest path from the input set to
  `v` using only edges of direction `dir` and relation `rel` (`both` =
  union of out- and in-edges per hop). Input nodes have level 0.
- The result is `{ v : m <= level(v) <= n }`.
- `(rel)` omitted ⇒ any relation. `{m..n}` omitted ⇒ `{1..1}`. `{m..*}` or
  bare `*` ⇒ unbounded max (terminates: a set can only grow to the node
  count).
- Corollaries (normative): `{0..0}` is the identity. An input node
  reachable again in k>0 hops has level 0, so it appears in the result
  **only if** m == 0. Each node is expanded at most once (the cost bound
  and the termination proof are the same fact). Self-loops contribute a
  level-1 reach of the node itself.

**`degree(dir) cmp K`** — keep nodes whose degree in the **full snapshot**
(not the induced subgraph) satisfies the comparison. `cmp` ∈
`< <= == >= >`.

### 3.3 Set operations (pop two, push one)

| Text | Semantics |
|---|---|
| `\| & $a` | intersection |
| `\| + $a` | union |
| `\| - $a` | difference: *accumulated set minus `$a`* (pipeline reading order) |

In the IR these are generic stack operations (the right operand is the
last pushed set); v1 surface restricts the right operand to a parameter.

### 3.4 Terminals (pop the final set; must be the last step)

| Text | Result | Determinism guarantee |
|---|---|---|
| `ids` | `[]u32` | sorted ascending, no duplicates |
| `count` | `u64` | cardinality |
| `exists` | `bool` | true iff non-empty; MAY short-circuit |
| `edges` | `[]EdgeRow` | edges with **both** endpoints in the set; sorted by (source, destination, prop_row); multigraph parallel edges appear once each; `prop_row` = 0 without edge properties |
| `csr` | `CsrView` | induced subgraph; offsets span ALL node ids (non-members have empty ranges); targets keep original ids and only include members |

Same input ⇒ byte-identical output. `exists` timing is the only permitted
observable variation.

### 3.5 Edge cases (normative)

- Empty sets propagate trivially through every op; an empty result is
  never an error.
- An empty parameter set is valid.
- `expand` over an empty relation (no matching edges) yields the identity
  for m == 0, else the empty set.

## 4. Textual grammar (v1, frozen; parser is future work)

```ebnf
query    = source , { "|" , step } , "|" , terminal ;
source   = "from" , ( param | "node:" nat | "*" ) ;
step     = expand | setop | filter ;
expand   = dir , [ "(" rel ")" ] , [ range ] ;
dir      = "out" | "in" | "both" ;
range    = "{" nat ".." ( nat | "*" ) "}" | "*" ;     (* default {1..1} *)
setop    = ( "&" | "+" | "-" ) , param ;
filter   = "degree" , "(" dir ")" , cmp , nat ;
cmp      = "<" | "<=" | "==" | ">=" | ">" ;
terminal = "ids" | "count" | "exists" | "edges" | "csr" ;
param    = "$" , ident ;
rel      = ident | nat ;                               (* idents via caller map *)
```

Whitespace is insignificant; `#` starts a line comment. One textual step
maps to one or two IR steps (`setop` = push param + stack op); the parser
is a 1:1 translation with no rewriting.

## 5. IR (wire format, frozen)

A plan is `{ steps: []Step, param_count: u16 }`. `Step` is 16 bytes,
extern, little-endian — the same bytes serve the C ABI:

```
offset  field  type  use
0       op     u16   operation (numbering FROZEN, see below)
2       dir    u8    out=0 in=1 both=2          (expand, filter_degree)
3       cmp    u8    lt=0 le=1 eq=2 ge=3 gt=4   (filter_degree)
4       rel    u16   relation; 0xFFFF = any      (expand)
6       param  u16   parameter slot              (seed_param)
8       hops   2×u16 {min,max}; max 0xFFFF = ∞   (expand)
12      arg    u32   node id (seed_node) / threshold (filter_degree)
```

Op numbers (frozen): `seed_param=0, seed_node=1, all_nodes=2, expand=3,
set_union=4, set_intersect=5, set_minus=6, filter_degree=7, emit_ids=8,
emit_count=9, emit_exists=10, emit_edges=11, emit_csr=12`. Values 13–15
are reserved for the §9 extensions; unknown ops are a validation error.

Unused operand fields MUST hold their defaults (`DirtyOperand` otherwise),
so plans compare, hash and dedupe structurally.

### Validation (the trust boundary)

Every plan that did not come from the comptime builder must pass
`ir.validate` before execution. Checks, in order: enum ranges decoded
defensively (hostile bytes), stack discipline (sources +1, set ops −1,
transforms 0; never below 1 operand for arity-1 ops or 2 for arity-2),
exactly one terminal and only as the last step (stack ends empty), every
`param` < `param_count`, `hops.min <= hops.max`, operand cleanliness.

## 6. The two surfaces

**Comptime builder (Zig)** — type-level chaining; malformed pipelines do
not compile; the plan is rodata. Mapping (1:1 with §3):

| Text | Builder |
|---|---|
| `from $0` | `Query.fromParam(0)` |
| `from node:17` | `Query.fromNode(17)` |
| `from *` | `Query.allNodes()` |
| `out(7){1..3}` | `.out(7, .{ .min = 1, .max = 3 })` |
| `out*` | `.outClosure(ir.ANY_RELATION)` |
| `& $1` / `+ $1` / `- $1` | `.intersectParam(1)` / `.unionParam(1)` / `.minusParam(1)` |
| `degree(in) >= 2` | `.filterDegree(.in, .ge, 2)` |
| `ids` … `csr` | `.ids()` … `.csr()` |

**Runtime plans** (future parser, C ABI): same `Plan` type, `ir.validate`
mandatory.

## 7. Execution contract

`exec.run(plan, view, ctx, params) → Result`. Implementations MUST honor:

- **Cost**: every step is one pass over its operands; `expand{m..n}` is at
  most n level-synchronous frontier sweeps with a visited bitmap; no step
  introduces hidden quadratic work. No planner exists, so no plan can run
  a different algorithm than the one written.
- **Bind**: `params.sets.len == param_count` (`ParamCountMismatch`),
  out-of-range ids error (`InvalidNode`), removed ids drop, duplicates
  dedup.
- **Determinism**: as per the §3.4 table.
- **Memory**: working sets live in the query `Context` arena; results are
  caller-owned allocations (`Result.deinit`).

## 8. Versioning and stability

- This is **Wayfind v1**. `wayfind.VERSION == 1`.
- Frozen for all of v1.x: `Step` size/layout, existing op numbers and
  their semantics, the grammar of §4, the determinism guarantees of §3.4.
- Allowed in v1.x: NEW ops appended (13+), new terminals/keywords from the
  reserved list, new builder methods — never changing existing meaning. A
  v1 validator rejects plans using ops it does not know (forward
  compatibility = explicit failure, never misexecution).
- Anything else is v2.

## 9. Reserved extensions (not in v1)

Reserved keywords: `paths`, `shortest`, `reach`, `to`, `walk`, `sample`,
`top`, `let`, `as`. Reserved op values: 13–15 (then 16+ as needed).
Planned, in rough order: `shortest`/`paths` terminals (path capture needs
its own result shape and explicit bounds), sub-pipeline set operands in
text and builder (the IR stack already supports them), execution over
frozen mmap graphs, the textual parser, the C ABI (`Plan` bytes + Arrow
param arrays).

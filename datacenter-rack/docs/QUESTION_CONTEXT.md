# Question context and inspection intents

`source/question_context.py` retrieves saved metadata and emits a proposed inspection intent. It uses Python's standard library, has no Blender import, performs no network requests, calls no language model, and never loads or frames geometry itself. The default scene can remain a single stack of exterior server models while this metadata is available independently.

```python
from question_context import resolve_question

result = resolve_question(
    "what does U14 do?",
    selected_part_id=None,
    server_id="rack01.server01",
    selected_metadata=None,
)
# result["intent"] == {
#   "action": "inspect", "asset_id": "server.motherboard",
#   "server_id": "rack01.server01", "part_id": "pcb.U14"
# }

# Integration owns actual execution and must check the loader result:
if result["status"] == "resolved" and result["intent"]:
    loader_result = lazy_inspector.handle_intent(result["intent"])
```

`resolve_question` returns `status` (`resolved`, `ambiguous`, or `unsupported`), `intent` or null, `answer`, `sources`, `candidates`, and `limitations`. Additional fields preserve per-fact evidence levels, component keys, source paths/locators, population provenance, uncertainties, the component-library hash, source revision and a more specific `reason_code`. `execution_status` is always `not_executed`: retrieval does not prove that a model loaded or a part was found.

Pass the current server selection on every call. The demo default is `rack01.server01`. Explicit text such as “show CPU in server3” changes it to `rack01.server03`; with current selection `rack02.server08`, it becomes `rack02.server03`. Multiple requested servers produce candidates and no load intent. A protocol-valid ID is not proof that the server exists: the loader must validate it against the actual rack manifest.

| Question | Proposed action |
|---|---|
| `show CPU` | Inspect `processor.study` for the current server |
| `show CPU in server3` | Inspect `processor.study` for server03 in the current rack |
| `what does U14 do?` | Inspect `server.motherboard`, `pcb.U14`; retrieve AST2500 role and source locators |
| `what does U17 do?` | Inspect the BMC's board-mounted Micron memory on `server.motherboard` |
| `show RAM` | Inspect `server.memory`; retain the explicit host-RDIMM analogue status |
| `show CPU socket` / `show DIMM sockets` | Inspect motherboard socket evidence, keeping socket and processor identities distinct |
| `why fan` / `show CPU fan` | Inspect `server.mechanical`; retrieve named source geometry and the airflow/heatsink explanation |
| `explain voltage management` | Inspect `server.motherboard`; retrieve distinct UCD90160 sequencing, ISL68137 control and Vicor conversion roles |
| `show heatsink` / `show drive` | Inspect `server.mechanical`, with candidate records and remaining identity limits |
| `what is this` | Resolve the selected part's refdes, component key, MPN, CAD identity or explicitly unverified scene metadata |
| `show rack` / `back to rack` | Emit `{"action":"show_rack"}`; loader owns unloading detail and framing the rack |

Explicit source reference designators and exact MPNs take precedence over familiar-name matching and selected context. An explicit U17 in a question cannot silently become the selected U14. Multiple requested references or different component groups return candidates instead of choosing one. Exact MPNs that occur at several references resolve the component type and offer the references; no arbitrary first occurrence is selected. Named references containing underscores are supported.

The resolver loads these saved files, never geometry:

- `source/component-library.json`: component identity, documented function, evidence levels, sources and uncertainties.
- `research/pcb-population/population-source.json`: authoritative native EDA placement and source population state.
- `models/configuration-receipt.json`: current source-CAD selection and recorded refdes mapping.
- `models/barreleye-evt-mesh/assembly.json`: source CAD names, hierarchy and source hash.

A reference listed as depopulated remains a depopulated source footprint. A source reference without a BOM match retains its unresolved identity; its component function is not fabricated. Generic passive/connector descriptions retain `category_inference` rather than being presented as a proven per-net circuit role. CAD names establish source identity/geometry context, not hidden function. Unknown or excluded parts produce no invented target. Live temperature, RPM, voltage-reading and fault requests are unsupported without actual telemetry.

The factory host CPU/DIMM/drive SKUs, serial numbers and live health are not supplied. Host RAM records are explicitly illustrative. The processor study's internal geometry is explanatory. Selected scene descriptions that cannot be joined to evidence are marked `selected_scene_metadata_unverified`. Source strings and metadata are never interpreted as instructions.

## Agent interpretation contract

For arbitrary natural-language questions, call `get_agent_context(question, **selection)`. It returns the retrieval packet, `AGENT_PROMPT`, `INTENT_SCHEMA` and the four supported asset IDs. A real Codex/Astra agent can reason over those facts, retrieve more source context when needed, write a sourced explanation, and choose one valid intent. The deterministic topic match is not proof that the user's entire question has been answered. Neither the module nor the demo claims an LLM call occurred.

`validate_intent(intent)` validates the action shape. Actual asset availability, server existence, part uniqueness, append/unload behavior and framing belong to `lazy_inspector.handle_intent`. An unknown or ambiguous loader result must be shown, not converted to a success message.

```python
from question_context import get_agent_context, validate_intent, INTENT_SCHEMA
packet = get_agent_context("why is this part here?",
    selected_part_id="pcb.U14", server_id="rack01.server03")
```

A persistent UI can reuse the cached default metadata index. Call `clear_context_cache()` after regenerating any source JSON, or construct `QuestionContext(project_root=...)` for an independent snapshot. Optional paths on `QuestionContext` allow explicit data fixtures or alternative saved revisions.

## Actual verification log

The implementation was exercised with local `python3` heredocs importing `question_context`, calling real saved-data retrieval and asserting status, asset, server, part, evidence and protocol results. The initial thirteen-case smoke run completed in approximately 0.47 seconds including index construction on this machine; this is an observation, not a performance guarantee.

An eighteen-case targeted pass verified CPU routing, server03 parsing, lowercase U14, selected U14, explicit U17 overriding selected U14, mixed known/unknown references, CPU-fan phrasing, DIMM sockets, ambiguous memory controllers, multiple component groups, multiple servers, rack return, unverified selected metadata, CAD-selected motherboard identity, repeated socket MPNs, alternate MPN punctuation, absent telemetry and missing selected context. All passed, including protocol validation and `execution_status=not_executed`.

A further eight-case pass checked J34's depopulated footprint, unresolved `J_UART_LOM1`, U17's motherboard routing, a source category-inference record, CPU sockets, memory, fan and U14, with preservation of server `rack07.server04`. It also verified that `bpy` was never imported. One initial test assumed C1 was a populated generic capacitor; the actual source marked it depopulated, so that incorrect test assumption was replaced with a real category-inference record. No source data was changed.

These checks prove metadata resolution and protocol generation. They do not prove integrated UI execution, model loading, GPU/memory behavior, scene framing or visual quality; those require the caller's live lazy-loader checks.

Final boundary checks verified an exact MPN containing a colon (`MT40A512M16JY-083E:B` -> U17), preservation of the selected rack when parsing server3, an explicitly missing server context, invalid action rejection, invalid selected metadata/part-ID rejection, and the agent-context schema. A real source MPN with712reference occurrences (`RK73Z1ETTP`) returned50candidates and an explicit total/truncation indicator in a21,262-byte response. Each candidate bounds its reference list; the module does not expand a repeated MPN into a quadratic response.

Candidate arrays are capped at50; `candidate_count` and `candidates_truncated` preserve the total. A component-level candidate exposes at most16source reference examples and its total reference count. The caller can ask for an exact reference next.

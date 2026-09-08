# Observable production log

`actions.jsonl` is the root command/event timeline. Named specialist action logs retain bounded source research, CAD, component and inspector work. `commands/` contains reviewed command stdout/stderr copies indexed by SHA256; the private local raw directory is excluded. Raw and published hashes are linked in `commands/index.json`, including whether redaction changed the text. `live-*.json` are actual Blender bridge receipts. Early retrospective entries remain explicitly marked. Some subprocess logs end abruptly because a run was interrupted or the user stopped rendering.

These files document observable execution, decisions, errors, corrections and verification. They are not hidden model reasoning, an exact model API trace, a full chat transcript, or an uninterrupted screen recording. See `../docs/HACKATHON_PROCESS.md` for what each mechanism actually did.

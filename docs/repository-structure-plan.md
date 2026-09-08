# Repository consolidation

Status: directory migration implemented, verified, committed and pushed as `ef10dcb`. [HANDOFF.md](../HANDOFF.md) records Arav's implementation order and the baseline. Public Swift module names and the wire format are unchanged.

The product has three code owners: one native app, one reusable spatial framework, and one deployable backend. The former `apps/ios`, `packages/SpatialKit`, and `services/session` wrappers added navigation without representing additional applications, packages, or services.

```text
astra2026/
├── README.md
├── APPROACH.md
├── HANDOFF.md
├── app/                       # Universal iPhone/iPad product
│   ├── project.yml
│   ├── AstraSpatialDemo.xcodeproj
│   └── SpatialDemo/           # UI, conversation/audio, app composition
├── backend/                   # One deployable Node process
│   ├── src/                   # Session transport, Astra adapter, normalization
│   ├── test/
│   ├── package.json
│   └── Dockerfile
├── framework/                 # Reusable scene framework
│   ├── Package.swift          # Public products remain SpatialCore/SpatialApple
│   ├── Sources/
│   │   ├── SpatialCore/       # Values, validation, transactional reducer
│   │   └── SpatialApple/      # RealityKit, pointing, scene transport
│   ├── Tests/
│   └── contract/              # Language-neutral wire schema + shared fixtures
├── assets/                    # Approved geometry, semantic metadata, licenses
├── tools/
│   ├── Package.swift         # SceneLab and PointingReplay executable targets
│   ├── Sources/
│   ├── assets/                # Offline Blender/USD preparation
│   ├── checks/                # Focused provider and asset acceptance commands
│   └── dev-session.py
├── docs/
│   ├── architecture.md
│   ├── product.md
│   ├── research.md
│   └── evidence/              # Dated receipts and screenshots
└── .local/                    # Ignored tokens, logs, builds and raw downloads
```

## Dependency rules

- **App:** owns product UI, audio capture/playback, Realtime conversation orchestration and user intent. Calls the framework and the backend. It supplies its approved asset catalog to the framework.
- **Framework:** owns scene meaning, accepted state, native geometry/rendering, selection and input mapping. It has no app UI or rack-specific logic. Its language-neutral contract is also consumed by backend tests.
- **Backend:** owns OpenAI credentials, model calls, proposal normalization and acknowledged session context. It does not own device rendering or authoritative native scene installation.
- **Assets:** contains data consumed by the app. The framework receives generic descriptors; it does not import a particular rack catalog.
- **Tools:** exercise or build the production modules. The running product does not import its development tools.
- **Docs:** explains decisions and preserves evidence; `.local` contains disposable local artifacts and private development configuration.

`framework/contract` groups the shared protocol with the framework that defines its semantics. This does not turn JSON Schema into Swift-only data: the TypeScript backend still validates against those shared fixtures. Provider-specific tool schemas remain in `backend/src/astra` because they are an adapter to the portable contract.

## Migrated paths

| Previous | Current |
| --- | --- |
| `apps/ios` | `app` |
| `services/session` | `backend` |
| `packages/SpatialKit` | `framework` |
| `contracts` | `framework/contract` |
| `content` | `assets` |
| `scripts` and existing headless tools | `tools`, grouped by task |
| `evidence` | `docs/evidence` |
| Root architecture/product/research documents | `docs` |
| Ignored `runtime`, `build`, derived data | `.local` |

SceneLab and PointingReplay are now executable targets of one tools Swift package. PointingReplay's generated Xcode project is replaced by SwiftPM settings that preserve its MainActor isolation. It remains a command-line program with no UI, camera or renderer.

Keep the app, backend and framework as distinct modules. They have different dependencies and deployment responsibilities. A folder migration also should not split the scene coordinator's transaction/revision/cancellation ordering across new managers.

## Migration acceptance checklist

All migration checks below passed against the reorganized tree. The ordinary launch check passed on iPhone using its saved HTTPS endpoint and Keychain credential; the iPad has the updated app installed but its locked screen prevented launch verification. The migration was committed and pushed as `ef10dcb`. [Verification receipt](evidence/repository-migration.json).

1. Move tracked paths with history; update XcodeGen package/resource references and regenerate the app project.
2. Update SwiftPM local package identity separately from public module names. Update fixture locators in Swift and TypeScript, and Python/JavaScript repository-root discovery.
3. Consolidate tool targets and run both SceneLab validation and every synthetic pointing case.
4. Update current commands and Markdown links; retain historical evidence payload paths and hashes as originally recorded.
5. Migrate the private development token intact. Coordinate the service restart because running processes still write to their old log directories. Do not delete `runtime` as though it were dead source code.
6. Run backend typecheck/tests/build, framework tests, native app builds, packaged-asset digest checks and the saved-endpoint device connection check.

This plan reduces visible concepts to six owned directories. It does not introduce new processes, an orchestration framework, a shared JavaScript workspace or new runtime layers.

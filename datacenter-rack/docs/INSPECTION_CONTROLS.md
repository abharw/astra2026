# Rack Lab inspection controls

`source/rack_inspector.py` is a session-loaded Blender add-on. It adds a **Rack Lab** tab to the 3D View sidebar and does not alter asset geometry when loaded. No network request, external API, model inference, live voice guide, or machine-wide installation is involved.

## Open the inspector

Launch the asset with Blender's executable:

```sh
/path/to/Blender /absolute/path/to/asset.blend --python /absolute/path/to/source/rack_inspector.py
```

Alternatively open the script in Blender's Text Editor and choose **Run Script**. In the 3D View, press **N**, then choose **Rack Lab**. Loading a `.blend` alone does not execute the add-on; load the script again in each new Blender process. Ordinary saving preserves active restoration state in the scene. The module also exports `register()` and `unregister()` for controlled loading.

## Move between inspection scenes

The top row offers **Rack**, **Open server**, **Motherboard**, and **Processor** shortcuts when their corresponding scenes exist. No scene is created by these controls. The active scene's button appears pressed. Scene shortcuts and **Inspect Server** open the scene's assigned camera view, resetting only the viewport camera zoom and offset. Overlay settings, camera transforms and selection restrictions stay unchanged. Orbit out of camera view to inspect freely. Return to Object Mode before switching.

Select a server collection instance in the rack, then choose **Inspect Server** to open the editable scene named in its `service_scene` property. The rack instances remain lightweight collection instances; the service scene exposes their components for inspection. The shortcuts target `01 · Full rack`, `02 · Open server`, `03 · Motherboard fabrication`, and `04 · Processor study`.

**Frame selected** also handles collection instances: it composes the instance transform, collection offset, member world matrices and nested instance transforms, then frames the resulting bounds. A temporary bounds mesh exists only during the operation and is removed afterward. The original selection is preserved. Studio lights, cameras and objects in the scene's `/ studio` collection are excluded from part search, even when they carry generic part IDs.

## Find and inspect

Enter a word, part ID, CAD name, reference designator, MPN, manufacturer or description, then click the search icon. All entered words must match somewhere in the object's name or supported metadata. Search runs only when clicked; panel drawing does not scan the scene. The list shows the first 100 matches and the total count. Click a result row, then **Select result**.

Hidden or selection-disabled parts are not automatically revealed. Restore an existing isolation with **Show all**, or reveal the relevant collection/object intentionally in the Outliner, then select the result. Objects outside the current view layer cannot be selected.

**Frame selected** fits the selected parts and visible descendants in the current 3D View, while preserving the original selection. **Select owning assembly** walks upward to the nearest assembly marker or parent empty. A selected assembly remains selected; use the Outliner to choose a higher ancestor.

The metadata box reads the selected object's authored part ID, CAD name, reference designator, MPN, manufacturer, function, description, evidence level and source URL. These values retain their original evidence status. Missing data is not inferred. Long values are shortened for display; the full authored value remains under Object Properties → Custom Properties.

## Isolate and restore visibility

**Isolate** keeps the owning assembly, its descendants and parent chain visible, subject to the visibility the human already set. It stores the prior hide state of the current view layer. Repeated isolation retains that initial state.

**Show all** means *restore the visibility before Rack Lab isolation*. It preserves objects the human had already hidden and does not modify render visibility, collection exclusions, or collection viewport flags. If the original view layer is deleted, restoration reports the problem and retains the saved state. New objects created during isolation have no prior record and are left as they are.

## Separate parts, move them and restore

Choose an assembly, set **Separation** in scene length units, then click **Explode one level**. The direct children are offset radially and their descendants follow them. This is an inspection arrangement, not a physical disassembly sequence. An animated or constrained subtree is refused because its evaluated transforms may be controlled elsewhere.

The scene stores original world matrices, local basis matrices, parent-inverse matrices, parent references, parent type and parent bone for the entire affected subtree. **Restore original transforms** restores original parent relationships and world transforms in parent-first order. State uses Blender object pointers, so renaming a part does not break restoration. Only one explode operation can be active at a time. Save the `.blend` to retain the restoration state across closing and reopening; load the inspector script again before restoring.

Use Blender's ordinary **G**, **R**, **S**, axis constraints, numeric input and transform gizmos to inspect a selected object. For manual movement that should be reversible with **Restore original transforms**, begin an explode operation first: its snapshot records the selected assembly's original placement. Otherwise use Blender Undo to reverse ordinary movement. Restoring cannot recreate an object deleted during inspection; surviving parts restore and the operator reports deleted objects.

## Edit routed cables

Select a curve cable by its Outliner name or metadata search, then choose **Edit cable route points**. The operator selects only that curve and enters Edit Mode. Select a control point and use **G** to move it; press **Tab** to finish. Linked read-only curve data is refused. Blender Undo reverses route edits. Explode restoration restores object transforms, not control-point edits or other mesh/curve topology changes.

## Verification

Isolated tests in `research/inspector-tests/smoke.py` exercise metadata search, selection, owning assembly, explode, world-transform recovery, parent recovery after a manual reparent, isolation, prior hidden-state preservation, curve Edit Mode, registration cycling and an actual `.blend` save/reopen round trip. The fixture is explicitly test-only and is not part of the rack model.

`smoke-results.json` records 21 passing checks; `reopen-results.json` records 12 passing checks in Blender 5.3.0 Alpha. The reopening test includes a renamed object and verifies its saved pointer, world matrix and original parent. Headless tests cannot verify sidebar layout, framing in a real 3D View, or the full-model interaction; the integrating task owns those live GUI checks.

Navigation follow-up: `research/inspector-tests/navigation-smoke.py` records 15 passing checks in `navigation-results.json`: transformed and nested instance bounds, studio-floor exclusion, instance search, missing Processor scene, Inspect Server, Rack navigation, instance framing in a real VIEW_3D context, temporary-data cleanup, preserved selection, nonzero framing extent, assigned camera view and unchanged overlay flags. The test runs in an isolated background fixture; the integrating task still owns the visible real-model UI click-through.

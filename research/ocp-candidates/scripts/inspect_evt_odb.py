"""Extract source fields from ODB++ without inventing CAD package geometry.

Coordinates/height use inch-to-mm conversion verified against independent PCP
component-center reports. Rotations remain raw: ODB/PCP conventions differ.
Package extents are EDA package bounds, not a molded-body specification.
"""
import collections, json, re
from acquire import ROOT, log

base = ROOT / 'inspection/extracted/zaius-EVT/ODB'
eda = next(base.rglob('data'))
package_bounds = []
for line in eda.read_text().splitlines():
    if line.startswith('PKG '):
        fields = line.split()
        package_bounds.append(dict(index=len(package_bounds), name=fields[1],
                                   source_record=line, numeric_fields=list(map(float, fields[2:]))))
centers = json.loads((ROOT / 'inspection/evt-component-centers.json').read_text())
lookup = collections.defaultdict(list)
for c in centers: lookup[(c['side'], c['refdes'])].append(c)
components = []
for path in base.rglob('components'):
    side = 'bottom' if 'comp_+_bot' in str(path) else 'top'
    attrs = {}; component = None
    for line in path.read_text().splitlines():
        if line.startswith('@'):
            key, name = line[1:].split(maxsplit=1); attrs[key] = name
        elif line.startswith('CMP '):
            fields = line.split(';', 1)[0].split()
            rawattrs = line.split(';', 1)[1].split(',') if ';' in line else []
            attributes = {}
            for a in rawattrs:
                k, _, v = a.partition('='); attributes[attrs.get(k, k)] = v or True
            component = dict(side=side, refdes=fields[6], package_index=int(fields[1]),
                             x_inch=float(fields[2]), y_inch=float(fields[3]),
                             rotation_odb_deg=float(fields[4]), mirror_odb=fields[5],
                             attributes=attributes, properties={}, source=str(path.relative_to(ROOT)))
            component['x_mm'] = component['x_inch'] * 25.4
            component['y_mm'] = component['y_inch'] * 25.4
            candidates = lookup[(side, component['refdes'])]
            component['center_match_mode'] = 'exact-refdes'
            if not candidates:
                # PCP's fixed-width refdes column clips some long identifiers.
                # Preserve the real ODB identifier and report this correction.
                candidates = [c for c in centers if c['side'] == side and component['refdes'].startswith(c['refdes'])]
                component['center_match_mode'] = 'PCP-truncated-refdes-position-match'
            errors = [max(abs(c['x_mm'] - component['x_mm']), abs(c['y_mm'] - component['y_mm'])) for c in candidates]
            component['center_crosscheck_error_mm'] = min(errors) if errors else None
            if errors:
                best = candidates[errors.index(min(errors))]
                component['pcp_refdes_as_printed'] = best['refdes']
                component['rotation_pcp_deg'] = best['angle_deg']
                component['mirror_pcp'] = best['mirror_flag']
            if '.comp_height' in attributes:
                component['height_eda_mm'] = float(attributes['.comp_height']) * 25.4
            components.append(component)
        elif line.startswith('PRP ') and component:
            _, key, val = line.split(maxsplit=2)
            component['properties'][key] = val.strip().strip("'")
errors = [c['center_crosscheck_error_mm'] for c in components]
summary = dict(components=len(components), unique_refdes=len(set(c['refdes'] for c in components)),
               packages=len(package_bounds), missing_center_matches=sum(e is None for e in errors),
               max_center_error_mm=max(e for e in errors if e is not None),
               truncated_PCP_refdes_recovered=sum(c['center_match_mode'] != 'exact-refdes' for c in components),
               caution='Keep ODB and PCP angle/mirror conventions separate; package bounds do not establish molded body.')
(ROOT / 'inspection/evt-odb-components.json').write_text(json.dumps(components, indent=2))
(ROOT / 'inspection/evt-odb-package-bounds.json').write_text(json.dumps(package_bounds, indent=2))
(ROOT / 'inspection/evt-odb-summary.json').write_text(json.dumps(summary, indent=2))
log('odb-inspection', detail='Extracted ODB component properties, heights, raw rotations and package records; checked centers against PCP.', **summary)
print(json.dumps(summary))

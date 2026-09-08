# Airbnb photo-led spatial experiments

[New: floor-plan sheets for all five places](floor-plans.md)

September 8, 2026. Two listings were opened through the in-app browser with computer-use controls, their complete galleries scrolled, and 33 gallery assets exported and visually inspected. No floor-plan reference was used. These are **not blind image-only tests**: titles, room counts and gallery labels were exposed during navigation, and the second listing's descriptive text was returned by a DOM snapshot. The relationships below are tied to visible image evidence; prior exposure cannot be undone.

![Photo-based topology hypotheses](airbnb-hypotheses.png)

## A: Garden flat

Source: [Stylish 2BR Garden Flat Near GGP & The Presidio](https://www.airbnb.com/rooms/1586369805694396546). Twenty-two photos viewed as four contact sheets, with A11/A12/A14 reopened individually. The gallery also includes exterior/neighborhood imagery, so 22 does not mean 22 useful indoor angles.

| Relationship | Visual evidence | Status |
|---|---|---|
| Exterior path → entrance → living | A20 shows an open glazed door and vase; A19 repeats vase/bench/landscape painting; A02 looks past the bench into the white sectional room; A03 reverses the relationship. | Strong observed connection. |
| Living → kitchen | A06 shows living coffee table foreground and kitchen range/table beyond; A07/A08 repeat anchors. | Observed wide opening. |
| Gray-bed room → workspace | A04 desk/window and arched mirror; A11 same mirror and botanical print beside gray-bed opening; A12 reverse view shows closet/work-area side. | Likely adjoining zone, inferred by matched anchors. |
| Gray-bed room → wood-bed room | A14 shows the edge of the gray bed/rug beyond wood-bed room doorway; A12 shows the reverse passage toward a glazed exterior door. A21 shows gray bed through an interior glazed door. | Likely connection through a short passage; exact partition/offset unresolved. |
| Wood-bed room → outside | A15/A22 show a glazed exterior door alongside the window. | Door observed; exact route to A18 garden not established. |
| Bathroom access and bedroom-to-living link | A05/A16 establish bathroom fixtures but do not tie its doorway to the living/circulation photos. | Unresolved; groups remain unjoined. |

Wall anchors: living sectional beneath/near window and niches, TV/art opposite; kitchen range/hood and cabinetry, sink under windows, fridge beside counter; gray bed beneath fruit picture with sliding closet nearby; wood bed beneath horizontal art, external door/window on adjacent wall; bathroom vanity/mirror, shower, toilet/window. Actual room footprints, distances and compass directions remain unknown.

[Photo manifest with observations and source URLs](airbnb-evidence/a/manifest.json) · [Photos A01–A06](airbnb-evidence/a/overview-1.jpg) · [A07–A12](airbnb-evidence/a/overview-2.jpg) · [A13–A18](airbnb-evidence/a/overview-3.jpg) · [A19–A22](airbnb-evidence/a/overview-4.jpg).

## B: Pacific Heights suite

Source: [Pac Heights 3-rm suite. Private, safe, quiet.](https://www.airbnb.com/rooms/18981477). Eleven assets viewed as two sheets; B05 reopened individually. Nine assets depict interiors/details and two are informational graphics. The title differed from the earlier search-card wording; the opened page title is used here.

B02/B03 establish that the fireplace, two chairs, bay seat/window and bed occupy **one room**. B01 and B04 show the French-door connection to a separate sofa/dining/TV room from both sides. B05 looks through a doorway toward tiled steps matching the bathroom in B06, supporting a short connecting passage. B07 establishes storage shelves/robes and B09 establishes a microwave/coffee/mini-fridge alcove, but neither places its access in the overall layout. B08 is a ceiling-light close-up, and B10/B11 contribute no indoor topology.

This avoids an easy overcounting error: separate photographs of the fireplace sitting zone and bed do not imply two rooms. Mirrors are reflections, not extra openings. The description mentions entry, patio and other relationships, but those are not promoted to photo-observed connections.

[Photo manifest](airbnb-evidence/b/manifest.json) · [B01–B06](airbnb-evidence/b/overview-1.jpg) · [B07–B11](airbnb-evidence/b/overview-2.jpg).

## What the comparison shows

Photos can support local room relationships when the same door and distinct objects appear from both sides. They cannot supply missing camera travel between disconnected photo groups. The continuous supplied home video gives stronger route evidence; even that video required a denser rewatch to correct kitchen orientation. These few examples are qualitative experiments, not an accuracy benchmark. No host ground truth, measured plan, calibrated pose or complete 360 coverage was obtained.

[Machine-readable relationships](airbnb-spatial-data.json) · [Full workflow record](astra-process-log.md) · [Video tour-point data](guided-tour-plan.md).

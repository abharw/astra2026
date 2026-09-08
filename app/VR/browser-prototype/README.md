# Browser interaction prototype

The first stage was a Three.js speaker exploration screen, originally run through Vinext and Sites. It established orbiting, component selection, hologram/material styles and exploded/assembled views before moving to native AR.

Public demo: https://speaker-hologram-lab.akeilsmith.chatgpt.site/

This is a source snapshot of the authored screen and its dependencies, not a standalone distribution of the Sites hosting environment. Hosting configuration and generated runtime files were deliberately excluded. The original page references `/reference.jpeg`; supply a permitted reference image locally if recreating the screen. The source photo is not in this repository. Use the native app under `../spatial-assembly` for the current runnable implementation.

The five component groups are authored specifically for the speaker photo. They are not the arbitrary-object generation pipeline used by the later iPhone app. Cabinet depth and hidden driver internals are approximate or inferred; the UI labels that distinction.

A React effect bug was fixed during live verification: effect callbacks used for imperative updates must return nothing, not the numeric result returned by an update operation. Interaction checks were repeated after that fix.

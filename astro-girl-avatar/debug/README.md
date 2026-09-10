# Synthetic voice regression replay

This optional developer probe sends a quiet excerpt of the bundled synthesized voice while a Realtime reply is being generated. It does not record a microphone or save API credentials. It requires Python with numpy and websocket-client, plus the existing private server key file. Running it uses the live API.

`python3 debug/probe-interruption.py --current --assert`

The recorded baseline canceled the reply at 0.233 seconds before audio began. Disabling automatic interruption prevented cancellation. Reducing reasoning effort from its default to minimal reduced first-audio time from 6.626 seconds to 0.650 seconds in the controlled comparison. The final configuration replay produced first audio in 1.100 seconds with no cancellation. These are individual synthetic replay measurements, not a real-room latency guarantee. JSON files contain event types and timings only.

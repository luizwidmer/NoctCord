# Security Policy

Noct Cord is pre-1.0 and has not received an external security audit. Do not
treat it as production-certified software.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting or a private security advisory
after the repository is published. Until then, contact the repository owner
through the verified GitHub profile. Do not include private keys, live relay
capabilities, personal media, or message plaintext in a report.

Include the affected commit, platform, reproduction steps, impact, and the
smallest safe proof of concept. Please allow time to investigate before public
disclosure.

## Security boundary

The relay must not receive plaintext messages, attachment keys, filenames, SDP,
or ICE candidates. A compromised endpoint or operating system, traffic-analysis
adversary, TURN operator, and unknown media-decoder flaw remain outside the
guaranteed protection boundary. See `README.md` and `docs/media-and-calls.md`
for current claims and limitations.

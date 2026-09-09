# agent-comms feature scripts

Installed by `./scripts/enable-feature.sh agent-comms` into the derived
repo's `scripts/agent-comms/` directory.

## Files

- `ask.sh` — cross-agent question primitive (discovery or direct mode)
- `enroll.sh` — interactive registration with the LA3D-LLM-Agents federation
- `README.md` — this file

## Quick start

After enabling the feature, register this repo:

```
bash scripts/agent-comms/enroll.sh
```

Then ask a question:

```
bash scripts/agent-comms/ask.sh "what does chrissweet/agent-comms do?"
```

See the [design page](https://github.com/LA3D-LLM-Agents/agent-comms/wiki/Comms-Feature-Design)
for the full architecture, the three communication modes, and the
testability env-var contract.

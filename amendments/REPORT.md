# Post Fiat testnet amendment state (2026-10-21)

Source: one live run of `pft-amendments.py` at commit `b30d83244d8f78048247ffa2a35d03347a024c16` against a
synced testnet node (`server_state: full`, build `1.0.9`, validated ledger 7353541), 2026-10-21T10:12Z,
Ubuntu 22.04.5 LTS. Raw log: [`../logs/amendments/1-live-run-and-negative-tests.log`](../logs/amendments/1-live-run-and-negative-tests.log).

| Metric | Count |
|--------|------:|
| Amendments known to build 1.0.9 | 101 |
| Supported by this build | 101 |
| Enabled on the network | 64 |
| Enabled but unsupported (amendment-blocked risk) | **0** |
| Holding a majority, pending activation | 0 (the Amendments ledger object has no `Majorities`) |
| Not enabled, this node votes no (`vetoed: true`) | 17 |
| Obsolete (can never be enabled) | 20 |
| `server_info.amendment_blocked` | false |

Every amendment in the network's Amendments object is supported by 1.0.9, and no vote is in progress,
so no upgrade is needed for amendments right now. The tool exited `0`.

The 17 amendments that are not enabled and get a "no" vote from this node (default-no, with no
`[amendments]` or `[veto_amendments]` stanza in this node's config):
LendingProtocol, MPTokensV1, PF_AccountExclusion, PF_ValidatorVoteTracking, PermissionedDEX,
PermissionedDomains, SingleAssetVault, TokenEscrow, XChainBridge, fixAMMClawbackRounding, fixDirectoryLimit,
fixIncludeKeyletFields, fixMPTDeliveredAmount, fixPayChanCancelAfter, fixPriceOracleOrder, fixTokenEscrowV1,
fixXChainRewardRounding.

## Fees (drops; 1 PFT = 1,000,000 drops)

| Setting | Network (FeeSettings, legacy format) | Validated ledger | This node's vote |
|---------|------:|------:|------|
| Base fee | 10 | 10 | default (no `[voting]` stanza) |
| Base reserve | 10,000,000 (10 PFT) | 10,000,000 | default |
| Owner reserve (per object) | 2,000,000 (2 PFT) | 2,000,000 | default |

Open-ledger fee at the time of the run: 10 drops (minimum 10, median 5000).

This node has no validator token, so it does not vote on the network. The vote columns show the stance
it would take.

Negative tests in the same log: the `enabled-unsupported` fixture (fake amendment `FFFF…0001` enabled in
the ledger but `supported: false`) exits `2`, and so does the `pending-unsupported` fixture (the same fake
amendment holding a majority). The 8 unit tests pass and `ruff check` is clean.

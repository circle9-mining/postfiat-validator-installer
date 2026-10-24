# Sentry-node setup (relay VPS in front of a private validator)

Follows the sentry pattern in Post Fiat's validator guide: the validator only peers with a disposable relay
("sentry"), so its real IP is not advertised to the network.

```
 network peers ──> sentry VPS :2559 (nginx stream) ──> 127.0.0.1:2560 postfiatd (public full node, "sentry")
                                                              ^
 validator [ips_fixed]=sentry, [peer_private]=1 ──────────────┘   (validator dials out; inbound 2559 only from sentry)
```

## Files
- `relay-setup.sh` – on the relay: nginx + stream module, forward TCP 2559, UFW allow 2559 (+SSH).
- `sentry-node.sh` – on the relay: runs a public `postfiatd` full node in Docker on 127.0.0.1:2560 (rolling `testnet-light-latest` tag, as in the official guide), with `no-new-privileges` and log rotation.
- `validator-setup.sh apply|revert` – on the validator: `[ips_fixed]` = sentry, `[peer_private]=1`, `[ips]` removed (config backed up), inbound 2559 limited to the sentry IP via UFW **and** DOCKER-USER (Docker-published ports bypass UFW), restarts `postfiatd`, waits for `full`. `revert` restores everything.

## Deviation from the task card (read first)
The card describes nginx forwarding 2559 **to the validator**. I implemented and tested that exactly
(`relay-setup.sh` default; `VALIDATOR_ADDR=...`): with the sentry as the validator's only configured peer, the validator dials the
relay, nginx forwards the connection back to the validator itself, and it stays `disconnected` with 0 peers
(`logs/sentry/1-card-literal-validator-*.log`). So the working topology forwards to a real `postfiatd` full node on the relay
(`UPSTREAM_ADDR=127.0.0.1 UPSTREAM_PORT=2560`, `sentry-node.sh`). The validator-side config is as on the card.

## Deploy
```bash
# relay (Ubuntu 22.04)
sudo ./sentry-node.sh
sudo UPSTREAM_ADDR=127.0.0.1 UPSTREAM_PORT=2560 ./relay-setup.sh
# validator (Ubuntu 22.04, /opt/postfiatd Docker install)
sudo SENTRY_IP=<relay-ip> ./validator-setup.sh apply
```
Relay choice: any small (1 vCPU/1 GB) Ubuntu 22.04 VPS with a stable public IP and 2559/tcp open; it is disposable,
so pick one you can destroy and recreate. In the test both hosts were on one private network.

## Verify
```bash
docker exec postfiatd curl -s -X POST -H 'Content-Type: application/json' http://127.0.0.1:5005 -d '{"method":"peers","params":[{}]}' | jq '.result.peers[].address'
docker exec postfiatd curl -s -X POST -H 'Content-Type: application/json' http://127.0.0.1:5005 -d '{"method":"server_info","params":[{}]}' | jq .result.info.server_state
sudo ufw status | grep 2559; sudo iptables -S DOCKER-USER | grep pft-sentry
```
Note: the admin RPC rejects calls from the host through Docker's port mapping (`Forbidden`), hence `docker exec`.

## Test results (logs/sentry/)
- `3-validator-proof.log`: validator `full`, `peers: 1`, the only peer is the sentry; UFW allows 2559 only from the sentry.
- `3-sentry-proof.log`: relay nginx stream config, established connection from the validator, sentry node `full` with 11 peers.
- `4-validator-revert.log`: `revert` restores the original config/firewall; node back to `full`.
Limitations: the line "probe from this host to its own address" in the proof log is a local connection and does not test the
firewall; I had no third host to prove a non-sentry source is blocked. Public IPs are redacted.

## Fixed peer only (`fixed` / `unfixed`)
`sudo SENTRY_IP=<sentry-ip> ./validator-setup.sh fixed` adds the sentry as an `[ips_fixed]` peer and changes nothing else:
`[ips]`, `[peer_private]=0` and the firewall stay as they are (the validator still peers publicly). It backs up the config to
`postfiatd.cfg.pre-fixed`, refuses to run if an `[ips_fixed]` section already exists, restarts postfiatd and waits for `full`.
`unfixed` restores the backup and restarts.

Why: in the sysctl live proof (2026-10-23) the sentry rebooted and the validator never peered with it again. Both nodes were
at 10 peers, which is their outbound limit, so PeerFinder had no free slot to dial the other one, and an admin `connect` did
not get a connection either. Fixed peers get their own slot and are re-dialled after a disconnect. `fixed-peer-proof.sh` is the
live proof. It runs inside a `pft-maint` window with every ntfy target on a throwaway topic and an Alertmanager silence. It
applies `fixed`, waits for the sentry peering, restarts the sentry container, waits for re-peering, then re-accepts the
integrity baseline for the config change only (`logs/sentry/5-fixed-peer-proof.log`).

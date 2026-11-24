# A/B kernel admission for `cfw update-kernel`

Status: ported to upstream 2.17.1 (2026-11-23). The A/B admission tests pass 14/14; the 2.17.1 Launchpad control, firmware-admission, helper-library, and bundle-name tests pass. Historical live A/B rollback was validated on `vphone26s` (2026-11-23) on the 2.9.5 line; the 2.17.1 VM validation is recorded below.

## 2.17.1 port validation (2026-11-23)

- Built and signed Launchpad 2.17.1 (helper 22) and `VPhone.bundle` 2.17.1, installed the local bundle as `2.17.1-local.4f8f5656`, bound `vphone26`, and updated its guest environment. Baseline: active `A` (`ad9302…`), standby `B`.
- The trace536 + display-promotion candidate `B` (`6034c2…`, 86 patches) panicked in launchd with a PAC failure; `cfw boot-rollback` restored `A`, marked `B` bad, and the restored `A` answered vphoned after 4 s.
- A trace-off/display-promotion-off candidate `B` (`1b562e…`, 83 patches) booted; `cfw boot-commit` promoted it (`active: b`, `A` standby), wrote a `booted` receipt for slot `B`, and the committed `B` booted and answered `device.info`.
- **Trace536 root cause and fix:** the cave epilogue restored `x19/x20` before `x21/x30`; the second load put the saved `x20` into `x30`, so `retab` failed at cave `+0x78` (`0xAB18BC`). Restoring `x21/x30` first (and `x19/x20` second) fixes it. The fixed bundle is `2.17.1-local.d149f226`; a trace-on/display-promotion-off candidate (85 patches) booted, vphoned answered, `cfw boot-commit` made slot `A` active with a `booted` receipt, and the committed `A` re-booted and answered vphoned.
- Final `vphone26`: active `A` (trace536 on, display promotion blocked), `B` standby, stopped. `vphone26s` was rebound to `2.17.1-local.d149f226` with the 2.17.1 guest environment; it booted and answered vphoned. It was then given the same trace-enabled candidate (`546056…`, 74 patches): it booted, vphoned answered, `cfw boot-commit` made slot `A` active with a `booted` receipt, and the committed `A` re-booted and answered vphoned. Both machines stopped.
- **Installing-state fix:** a failed install step with no `error` text left `isInstalling` true. `InstallProgress.overall` now treats any failed step as `.failed`; `canSkip` allows skipping a failed post-install check; `isInstalling` is true only while overall is `.running`. The stale `bundle-install.json` was removed; the fixed app reports `installing: false`, `canInstallBundles: true`, helper `ready (22)`.
- Guest infrastructure: `ui.describe`, `apps.list`, `processes.list` (200), and a locked screenshot succeeded; unlock succeeded, but the guest agent dropped before the next screenshot on the older 2.9.x boot chain. The rebooted trace-fixed `A` answered vphoned; `vphone26s` also answered vphoned after rebinding.
- Host tests: A/B 14/14; Launchpad 13 shell scripts; CoreKit 784; Restore 73; Sign 30; FirmwarePatcher 1023/1028 (5 missing local `ipsws` fixtures); ArchiveKit 101/103 (one host-tar parity failure).
- The d149 bundle install passed both policy and preflight; the earlier 4f8 install's AMFI allow step failed because `amfid` had idle-exited. The fixed app's install state no longer sticks.




## Why

`cfw update-kernel` replaced the only Preboot kernelcache in place and printed
“start the VM”. If that kernel panicked, nothing on the host knew which bytes
had booted before, and the VM’s only kernel was the failed candidate. The
second failure was that the update could be repeated over an untested kernel
with no record of what was pending.

## State

The VM folder carries:

| Path | Meaning |
|---|---|
| `BootSlots/a.img4`, `BootSlots/b.img4` | Full Preboot kernelcache IMG4 snapshots, one per slot |
| `BootState.plist` | Active slot, both slot artifacts, pending candidate, failed attempts |
| `BootReceipt.plist` | Last commit/rollback: slot, kernel SHA-256, result, evidence, date |

The state is an enum-free data model in
`FirmwarePatcher/CustomFirmware/FirmwareBootAdmission.swift`: a slot holds a
SHA-256/size artifact, an enabled-kernel-patch list and a state
(`active`/`standby`/`candidate`/`bad`). The candidate slot is always the
inactive slot.

## Update

`cfw update-kernel` on a stopped VM:

1. Reads the current Preboot kernelcache IMG4 and builds the candidate from
   `FirmwareOriginals` with the VM’s current selection.
2. Loads `BootState.plist`; a pending candidate refuses another update.
3. Verifies the current Preboot kernel matches the recorded active slot; a
   mismatch is a stale state, not a reason to overwrite.
4. Writes the active snapshot on the first run, writes the candidate to the
   inactive slot, and records a pending `installed: false` state.
5. Replaces the Preboot kernelcache, then records `installed: true`.
6. Prints the `cfw boot-commit <vm>` command.

A failed Preboot write clears the pending state; the active kernel remains.

## Commit

`cfw boot-commit <vm>` is non-root and requires the VM to be stopped (no
process holds `Disk.img`). It refuses a pending candidate that never landed,
promotes the candidate, turns the previous slot into standby, writes the
receipt, and records evidence supplied by the owner (default: operator
confirmed the guest booted).

## Rollback

The pure state machine (`rollback(state:result:evidence:now:)`) keeps the
active slot, marks the candidate bad and records the failure. The root verb is
`cfw boot-rollback <vm>`: it requires root and a stopped VM, verifies the
active slot's SHA-256, writes that IMG4 back to Preboot in a disk clone, marks
the candidate bad, records the `panicked`/failed receipt and clears the
pending candidate. It was run live on `vphone26s` after the candidate panic;
slot A was restored and the twin booted.

## Validation

Target: `vphone26s` (the stopped, CFW-installed 2.9.5 twin). `vphone26` was
left untouched.

What ran:

1. Blocked `kernel-cfw-display_promotion` in `vphone26s/PatchSelection.plist`
   (backup `/tmp/vphone26s-PatchSelection.plist`, sha256 `66cb1b45…`).
2. Installed the local 2.9.4 bundle (`2.9.4-local.1f8e6925`) and ran the
   helper’s `cfw update-kernel`; it wrote the active `A` snapshot, put the
   candidate in `B`, set `pending.installed = true`, and replaced the Preboot
   kernel.
3. Started `vphone26s --headless --wait`. The candidate **panicked** with
   `PAC failure from kernel with IB key while returning at pc
   0xfffffe004c989850`; the start returned a kernel panic, and no
   `BootReceipt.plist` existed. Slot `A` still held the previously booted
   kernel (`768e7aba…`), `B` held the candidate (`289068ca…`).
4. Ran the new root `cfw boot-rollback vphone26s` with the panic evidence. It
   wrote slot `A` back to Preboot, marked `B` bad, cleared the pending
   candidate, and wrote `BootReceipt.plist` (`slot b`, `panicked`, the PAC
   evidence) and `PatchReceipt.plist` (`kernelcache writer=cfw boot-rollback`,
   34 patches).
5. Started the restored slot A: vphoned answered after 7 s, `state: running`,
   `panicked: false`.

Result: the A/B transaction and the root rollback work live. The failed
candidate never became active; the previously booted kernel was restored and
booted.

Finding: the candidate came from the 2.9.4 kernel-patch pipeline (75 patches),
while the twin’s previously booted kernel came from the 2.9.5-created image
(34 patches). The 2.9.4 kernel-patch set is not boot-safe on this VM; the
2.9.5 kernel boots. Port the boot code to the 2.9.5 source (or fix the 2.9.4
kernel patch catalog) before testing the `cfw boot-commit` success path with a
bootable candidate. The pure `FirmwareBootAdmissionTests` cover commit/rollback
state transitions; `cfw boot-commit` was negative-tested live (no pending
state) and remains unexercised live on a bootable candidate.

The twin is restored to `2.9.5-local.25a0e269` with its original 29-block
selection; the A/B state, the panicked receipt and the installed 2.9.4 build
are kept for the port. The kernel-update transaction now requires 4 GiB free
(the full install still requires 50 GiB); this run needed the build products
deleted first because the host disk was at 98%.

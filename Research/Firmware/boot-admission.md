# A/B kernel admission for `cfw update-kernel`

Status: live A/B rollback, commit and restored-boot validated on `vphone26s` (2026-11-23) on the rebased 2.15.2-lineage port. The 2.9.4 kernel-patch pipeline remains the unsafe candidate.

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

Result (2.9.4 candidate): the A/B transaction and the root rollback work live.
The failed candidate never became active; the previously booted kernel was
restored and booted.

Finding: the candidate came from the 2.9.4 kernel-patch pipeline (75 patches),
while the twin’s previously booted kernel came from the 2.9.5-created image
(34 patches). The 2.9.4 kernel-patch set is not boot-safe on this VM; the
2.9.5 kernel boots. The 2.15.2-lineage port's 72-patch kernel is also
boot-safe; the failure is specific to the 2.9.4 pipeline, not to a high patch
count.

### Rebased port validation (2026-11-23)

The boot code was rebased onto `8c5aa439` (the 2.15.2 source recorded by the
old `2.9.5-local` bundle) instead of the 2.9.5 tag, because the tag predates
the Frida patch and cannot reproduce the bundle's patch set.

1. Built `2.9.5-local.eda804b0` (Info.plist versioned 2.9.5 for the Launchpad
   series) and ran `cfw update-kernel` on `vphone26s`: 72 kernel patches, the
   active slot snapshotted, the candidate written to the inactive slot, and
   `pending.installed = true`.
2. Started `vphone26s --headless --wait`: vphoned answered in 5 s,
   `panicked: false`.
3. Stopped and ran `cfw boot-commit`: slot `B` committed, slot `A` standby;
   `BootReceipt.plist` result `booted`, kernel SHA-256 `e412bb65…`.
4. Temporarily unblocked `kernel-cfw-display_promotion` (backup
   `/tmp/vphone26s-PatchSelection-before-rollback.plist`) and ran
   `cfw update-kernel` again; the candidate in `A` was distinct from the
   active `B`.
5. Ran root `cfw boot-rollback`: Preboot restored to slot `B`, slot `A`
   marked bad, `failedAttempts = 1`, `BootReceipt.plist` slot `a`, result
   `panicked`, candidate SHA-256 `768e7aba…`.
6. Started the restored slot `B`: vphoned answered after 5 s,
   `panicked: false`; `BootState` active `B`, `A` bad.

The twin is stopped, bound to `2.9.5-local.eda804b0`, and its selection is
restored. `vphone26` was left untouched. The kernel-update transaction
requires 4 GiB free (the full install still requires 50 GiB); this run needed
the build intermediates deleted first because the host disk was at 97–99%.

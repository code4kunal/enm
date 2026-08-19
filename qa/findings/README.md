# Findings

One file per bug, named `YYYY-MM-DD-NNNN.md`, from `TEMPLATE.md`.

Every finding carries a test in the floor. That is what stops the same bug being
found twice, and it is why the hunter earns its tokens: its output is not a
report, it is a permanent raising of the floor.

A finding is never closed by weakening its test. It is closed by the app doing
what `design/HANDOFF.md` says, or by the handoff being formally amended.

A test attached to an open finding is `skip`ped with the finding's number in the
reason, never left red. A merge gate that is red by default is a gate everyone
learns to ignore.

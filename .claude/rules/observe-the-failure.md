# Observe the failure before you trust the fix

Evidence is only evidence if it could have come out the other way.
Ask of any green, any pass, any answer you are about to rely on: what would I see if the claim were false?
If you would see the same thing, the signal carries no information and you have verified nothing.
Proof is a contrast you witnessed: the failure present beforehand, gone afterward, your change the only thing that moved.

## A test you run, not a list you match

The sections below are that one question applied, not a catalog of banned patterns.
When you meet a signal not described here, run the question on it: could this have failed, and did you watch which way it came out?
The question binds any result you act on or pass along, a test you call passing, a number you report, an answer you relay, the moment it leaves your hands in a commit or a message; pure exploration you discard binds nothing.

## Arrange to see the failure first

For a bug, reproduce the wrong behavior on demand before you touch the code: the reproduction both proves the bug is real and defines what the fix must change.
For new behavior, writing the test before the implementation is the usual way to arrange a failure you can observe before the code exists.
Either way, run the sequence in order: see it fail for the reason you intend, apply the change, see the failure gone, then revert and confirm it returns.
Skip that first observation and a green result proves only that the code passes now, not that you changed the thing you meant to.

## The failure you observe must be the real one

It must come from the specific behavior you are targeting, not a proxy.
A red that is an import error, a missing name, or a setup failure does not count: the behavior you targeted never got the chance to fail, so its later pass would look the same whether the code is right or wrong.
Build enough scaffolding that everything resolves and the targeted assertion is the only thing that can fail, then read the failure instead of assuming it; if it is anything other than what you aimed at, the contrast is invalid.

## A pass on the first run teaches nothing

If a check goes green without ever having been red, you have not learned whether it can fail at all, so it would pass against unbuilt code just the same.
Assert the real outcome directly rather than inverting the logic to manufacture a pass.
Absence and negative assertions (nothing returned, the flag is off, no match) hold trivially against unreached code, so they cannot be the failure you observe; keep them as later guards, not as proof.

## When you did not write the red, create it

For a check you inherited, copied, or wrote already green (code you did not author, a pattern you reused), you have not seen it fail, so prove it can: mutate what it covers, confirm that check and only the expected ones go red for the right reason, then revert.
A check that stays green while its target is broken is empty; strengthen it until the breakage turns it red, or remove it.
This also catches the check that passes for lack of exercise, where the input never reaches the code under test: fix the input to drive the path, not just the assertion.
A check that round-trips through the very code it tests can never be made to fail this way, which is the signal that it is exercising the library, not your work.

## Every signal you rely on, not just tests

The same question governs assertions, monitors, alerts, type checks, and release gates.
An alarm that has never fired might be wired to nothing; before you trust a guard to catch a regression, watch it catch one.
A subagent's answer is such a signal: it has only ever returned, you have never watched it be wrong, so accepting it is uninformative unless you arranged some way it could have been rejected.
Trust a delegated answer only as far as the evidence it cites that you can check yourself, a file:line, the actual command output, never the bare conclusion; relaying a conclusion you have not reduced to checked evidence is the same failure as claiming a fix you never saw fail.

## Show the contrast, do not just assert it

Internalizing the question is what makes you run it; exhibiting the result is what makes the result trustworthy.
Report the failure you saw and the pass that replaced it, the real output, not "it works" or "tests pass."
A green you cannot show is one you have not earned.

## Your own fixtures are self-consistency, not correctness

A passing suite proves the code does what your tests say, not that your tests match reality.
Hand-built inputs encode your assumptions, so they hide the ones that are wrong; exercise the change against real data too, and treat any behavior only real data reveals as the next failure to observe.

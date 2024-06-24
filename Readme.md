# Git Test Management

Problem: Developers flat-out refuse to use test management systems, so tracking test results over time is difficult

Possible solution: Integrate test management into the tool they already use.

Knock-on benefit: Test results no longer lost when CI systems go TU, CI can be simplified.

## How

Abuse of git-notes to store test results per sha so you can have them run as a pre-commit hook and note the results as a post-commit hook.

We store these things per test result (and append if we detect different test/environment than already logged):

1. Name of the relevant test & whether it overall passed/failed
2. Hostname of runner & other environmental information
2. The raw test output
3. Coverage matrix of said test so you can chart coverage as development trundles along.

To not pollute the normal stream of commit notes, we send this to a different ref:

`refs/notes/test\_results`

Obviously, in a repository with a large amount of tests this will result in a LOT of notes.
It is recommended that you set `notes.mergeStrategy` to `union` when using this.
Similarly, you should not add this ref to `notes.displayRef`.

## Format of notes

We divide the sections above with the following markers:

0. Test-Result-For: $TEST\_NAME OK|NOT OK
1. ----ENVIRONMENT----
1. ----RESULT----
2. ----MATRIX----
3. End-Test-Result-For: $TEST\_NAME

This allows for simple parsing and multiple results for the same test on differing platforms to be represented.

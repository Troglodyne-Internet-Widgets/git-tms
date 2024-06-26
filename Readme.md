# Git Test Management

Problem: Developers flat-out refuse to use test management systems, so tracking test results over time is difficult

Possible solution: Integrate test management into the tool they already use.

Knock-on benefit: Test results no longer lost when CI/Tracker/TMS changes/dies, testing stack can be simplified.

## How to use

Copy the hooks from hooks/ to the repo's .githooks folder.
You can then commit and push them.
They need to be tracked due to the particulars of your testsuite -- automated testing will necessarily be different for every project.
As such the pre-commit hook will need some adjustment.

Ideally you use some mechanism to only run relevant tests to the diff per commit in repositories with long-running/large testsuites.

`git diff --name-only $primary_target...$current_target` fed into a routine which filters out extraneous files is one such mechanism.
You can also look at coverage data from this to identify this list of relevant files.
Supposing you set your CI systems to run the full testsuite (or use a pairwise approach) the coverage data ought to be reasonably up-to-date for these purposes.

You then need to enforce that the users of the repository (or at least the CI systems) do this:

`git config --local core.hooksPath .githooks/`

Alternatively, you can integrate the hooks' techniques into some custom application in your workflow.

You can then install the companion application Git::TMS from CPAN:

`sudo cpan -i Git::TMS`

Which will expose the program `git-tms`, which will allow you to do such useful things as:

```
# Export the test results for a given period to sqlite, appending data if the db exists.  See schema/ for db design.
git tms export --append 0abcdef..HEAD results.sqlite3

# Show results & coverage & output for a sha on windows
git tms results --coverage --raw --os windows HEAD

# Find unreliable tests (where a pass and fail exist on the same SHA/environment)
git tms scan --unreliable 0abcdef..HEAD

# Record the results of a manual test, optionally tagging covered code (or if it does not exist, more nebulous things like concepts)
git tms record --covers myFeature --covers lib/FooModule --os templeOS --at HEAD t/manual/do-thing.md

```

## How it works

Abuse of git-notes to store test results per sha so you can have them run as a pre-commit hook and note the results as a post-commit hook.

We store these things per test result (and append if we detect different test/environment than already logged):

1. Name of the relevant test & whether it overall passed/failed
2. Hostname of runner & other environmental information
2. The raw test output
3. Coverage matrix of said test so you can chart coverage as development trundles along.

To not pollute the normal stream of commit notes, we send this to a different ref:

`refs/notes/test_results`

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

## Schema

The schema ought to be as generic as possible to account for multi-programming language repositories.
It is the responsibility of the individual parser modules for coverage & results to parse the data needed to fill export DBs.
These modules ought live in a `Git::TMS::Parser::*` namespace as a child of `Git::TMS::Parser`.

## The pre-commit hook

Tests ought to be run by this and deposited into $TMPDIR/git-tms-result-stream.
They will be cleaned up by the post-commit hook.

## The post-commit hook

This will append notes to the relevant ref.  Not much to it.

## The post-push hook

Pushes our relevant ref, as nobody properly configures what refs to push to, and besides that nobody wants a push to fail because our ref exploded for some reason.

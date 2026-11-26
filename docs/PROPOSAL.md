# git-tms: a proposal for building it

Revision 2. The owner answered the first round of questions. This revision
follows those answers:

- Store one JSON object per line.
- Anchor results on the tree that was tested, not on the commit.
- Produce results from a test harness plugin and coverage from a
  Devel::Cover report module, not from git hooks. A test harness runs the
  test files and reads their output. `prove` and `yath` are test harnesses. Design for CI and a matrix
  of hosts and configurations.
- Leave App-Prove-Elasticsearch out of the plan.

The git-tms repository has 13 commits, from 23 and 24 June 2024. Where a choice
comes from the owner's sketch or answers, the proposal says so. Where a choice
is mine, the proposal says so.

## 0. What version 0.01 did with this proposal

The owner wrote answers under the risks and the open questions of section 7.
Those answers override the rest of this document where they differ.  Sections
1 to 8 are kept as the owner answered them, so that later work has the
reasons.  Version 0.01 differs from section 5 in these ways:

- A record keeps output only for a test that did not pass.  It keeps the
  runtime of every test file.  It has no host name, no `env` field and no
  versions of dependencies.  The configuration is the unit.
- The yath plugin, `App::Yath::Plugin::GitTMS`, is in 0.01, beside the prove
  plugin.
- The output filter, `tms.outputFilter`, is in 0.01.
- A separate results repository is in 0.01.  `tms.remote` names the remote
  that `push` and `fetch` use, and a test covers a results repository that has
  none of the code.
- The code is written for Windows as well: `File::Spec` for paths, and no
  shell between git-tms and git.  Nobody ran it on Windows yet.
- The notes are not gzipped.  perl-tests-covering gzips its JSON because it
  writes a plain file.  Git already compresses each object with zlib, and
  compresses similar notes against each other in a pack.  A test with 300
  notes of 150 records each gave a pack of 692 KiB for plain notes and 690 KiB
  for gzipped notes.  A gzipped note also stops `cat_sort_uniq` from merging.
  So 0.01 keeps the size down by what it stores, not by compression.
- `results --stats` is not in 0.01.

Coverage is milestone 2.  Statement coverage percent for each file is enough
then.  Manual tests, retention and the other milestones of section 6 are not in
0.01.

## 1. The problem, and for whom

Developers do not use test management systems (TMS), so nobody can see how a
test behaved over time. The sketch puts it this way: "Developers flat-out
refuse to use test management systems". git-tms keeps test results and
coverage inside the git repository, keyed by the tree that was tested. A CI
matrix fills it, and every configuration writes its own results. The results
outlive any CI server, tracker or TMS.

The users are the people who run CI and read its results: developers who ask
"where does this test fail?", and maintainers who look for flaky tests and
coverage trends. Manual testers are a second, smaller group.

The owner's answer sets the scope: without CI and a matrix of hosts and
configurations, the results do not matter.

## 2. What exists today

| Part | State |
|---|---|
| `Readme.md` | The real content. It states the problem, the four commands, the storage idea, the note format and the role of each hook. |
| `bin/git-tms` | Argument parsing and dispatch for `scan`, `record`, `export` and `results`. It compiles. It does nothing else. |
| `lib/Git/TMS.pm` | Four empty subs, one for each command. |
| `lib/Git/TMS/Parser.pm` | `parse()` and a formatter for the marker format. `new()` is empty. `parse_output()` and `parse_coverage()` are stubs (`...`). |
| `hooks/pre-commit`, `hooks/post-commit`, `hooks/pre-push` | Empty files. |
| `schema/tms.sql` | Empty file. |
| Tests, `dist.ini`, `cpanfile` | None. |

Everything except the Readme is a sketch. After the owner's answers, the
hooks, the marker format and `Git::TMS::Parser` all leave the design. The
command line in `bin/git-tms` stays as the reading side. It has defects that I
found by running it:

- `help()` reads `$_` and not `@_`. The usage line prints `git tms [] ...`
  with no verbs.
- With no verb, `$command` is undefined, and Perl warns before the usage line.
- `results` declares `os` without `=s`. `git tms results --os windows HEAD`
  sets `os` to 1 and takes `windows` as the commit. (Checked with
  `GetOptionsFromArray`: `os=1 left=windows HEAD`.)
- `record` names its positional `test_name`, but the Readme example passes a
  path, and the example has no way to give a status.

The name `Git::TMS` is free on CPAN. A query to the MetaCPAN API for the module
returned 404.

## 3. Facts I checked

I ran the git checks in throwaway repositories with git 2.43.0, a bare
"origin" and several clones. I ran the Perl checks against the modules
installed on this machine: Devel::Cover 1.52, App::Prove and TAP::Harness 3.52,
and Test2::Harness 1.000182.

### Git notes

1. A plain `git push` does not send notes, and a plain `git clone` does not
   fetch them. Both need the notes ref named.
2. `cat_sort_uniq` merges notes that hold one JSON object per line with no
   duplicates. `union` copies every record that both sides had before they
   split.
3. A note can hang on a tree. The reader finds the results of a commit through
   the tree that the commit names (`<commit>^{tree}`).
4. `git log --notes=...` shows nothing for a note on a tree. It shows only notes
   on commits. `git notes list` gives the pairs of note and tree.
5. An amend or a rebase that keeps the tree keeps the results with no
   configuration. `notes.rewriteRef` is not needed.
6. Three clones wrote to three refs, `refs/notes/tms/results/<config>`, for one
   tree, and pushed one after the other. All three pushes went through, with
   no fetch and no merge.
7. One glob refspec, `+refs/notes/tms/*:refs/notes/tms-remote/origin/*`,
   fetched all three. A loop over those refs answered "which configurations
   fail `t/a.t` at this tree".
8. Two jobs of the same configuration wrote to the same ref. The second push
   was refused. A fetch into a side ref, a merge with `-s cat_sort_uniq` and a
   new push worked, and kept the records of both jobs.
9. A notes push carries the note, not the tree. A clone pushed notes for a
   tree that the remote did not have. The remote took the note and still did
   not have the tree. So results can go to a different repository from the
   code.
10. `git notes prune` deletes every note whose tree is not in the local
    repository. After a reset and `gc --prune=now`, it deleted the note of a
    tree that was gone. `git gc` alone does not prune notes.

### Devel::Cover report modules

11. `cover -report foo` loads `Devel::Cover::Report::Foo`. The `cover` script
    runs `eval "use Devel::Cover::Report::\u$report"`, so it upper-cases only
    the first letter. A report named `Gittms` is called as
    `cover -report gittms`.
12. If the module has `get_options`, `cover` calls it with the options hash
    and the remaining `@ARGV`. A probe module took `-probe_ref <value>` this
    way. Then `cover` calls `report($class, $db, $options)`. `$options` has
    `outputdir`, which is the `cover_db` directory.
13. Per-test coverage survives the merge. I ran two tests under
    `HARNESS_PERL_SWITCHES=-MDevel::Cover prove -l t`. The `$db` that the
    report got had one entry in `$db->{runs}` for each test. Each entry named
    its test in `run` (`t/a.t`, `t/b.t`), with `OS` and `perl`. It also had
    its own statement counts and an MD5 digest for each file. The two tests
    had different counts for the same module. If a file changed between
    runs, Devel::Cover drops the old counts for it (`DB.pm`, around line 250).
    Otherwise it keeps them.
14. The counts are in the order of Devel::Cover's structure, not by line.
    perl-tests-covering already turns them into lines and git blob ids, in
    `_files_covered` and `_record`.

### Test harness plugins

15. `prove -PFoo=a,b` loads `App::Prove::Plugin::Foo` and calls
    `load({app_prove => $app, args => ['a','b']})` (from the App::Prove POD).
    A plugin cannot add harness callbacks directly. It sets a harness subclass
    with `$app->harness('My::Harness')`. TestRail-Perl's prove plugin does
    the same.
16. A probe harness subclass added two callbacks. `made_parser` puts an `ALL`
    callback on each parser to collect the raw TAP. `after_test` gets the job
    and the parser. Under `prove -j2`, it saw each file with its status, exit
    code, plan, pass and fail counts and raw TAP. Raw TAP has no standard
    error unless prove runs with `--merge`.
17. `rprove` runs `App::Prove` on the local host, with an `--exec` shim that
    runs each test over SSH. So a prove plugin works with `rprove`. The
    plugin runs on the local host, so it must not detect the environment
    itself in that case.
18. Yath loads `App::Yath::Plugin::Foo` for `-pFoo`. A plugin can define
    `handle_event($event, $settings)` (called for every event) and
    `finish(%args)` (called at the end with the failed and retried jobs). I
    read this in the installed POD. I did not run a yath plugin.

I did not check how each git forge treats `refs/notes/*`. That needs a test
push to each forge that the owner uses.

## 4. Design

### 4.1 The parts

There are three parts, plus one shared library:

1. **Results producer**: `App::Prove::Plugin::GitTMS`, with the harness
   subclass `Git::TMS::Harness`. It writes one record per test file.
2. **Coverage producer**: `Devel::Cover::Report::Gittms`. It writes, for each
   test, the lines it ran in each file.
3. **The `git tms` command**: it pushes, fetches, queries and exports.
4. **`Git::TMS::Store`**: the library under all three. It reads and writes
   notes through `git notes` and does the fetch, merge and push.

The producers write only to the local clone. A separate step pushes. A CI job
then runs, for example:

```
HARNESS_PERL_SWITCHES=-MDevel::Cover prove -l -m -PGitTMS=config=linux-perl5.40 t
cover -report gittms -config linux-perl5.40
git tms push origin
```

So a broken network never makes a test run fail, and one push covers both
producers.

### 4.2 Data model: what lives in git

**Anchor: the tree that was tested.** This is the owner's answer ("Tree
probably better"). Each note hangs on a tree id. A commit finds its results
through `<commit>^{tree}` (fact 3). Commits with the same tree share results,
which is correct, because they hold the same code. If an amend or a rebase
keeps the tree, it keeps the results (fact 5).

The producer takes the tree from `git rev-parse HEAD^{tree}`. First it checks
that tracked files match `HEAD` (`git diff --quiet HEAD`). If they do not
match, the tested code has no tree id. The producer then writes nothing, and
says so (my addition). Untracked build output, such as `blib/`, does not change
the tree.

**Refs: one per configuration** (my addition, from the matrix). Results go to
`refs/notes/tms/results/<config>`, and coverage goes to
`refs/notes/tms/coverage/<config>`. A configuration is one cell of the CI
matrix, for example `linux-perl5.40` or `freebsd-perl5.38-nodeps`. The CI job
names it, through the plugin argument or `GIT_TMS_CONFIG`. It is not the host
name, because CI hosts come and go.

The sketch had one ref, `refs/notes/test_results`. One ref per configuration is
better for a matrix:

- Configurations never race each other on push (fact 6).
- "Which configurations fail this test at this tree" is a loop over refs, with
  one note read for each (fact 7).
- A reader can fetch only the configurations, or only the coverage, that it
  wants.
- Coverage, the largest data, stays out of a fetch of results.

Two jobs of the same configuration on the same tree still race. `git tms push`
handles it: it fetches, merges with `cat_sort_uniq` and pushes again (fact 8).

The sketch keeps the ref out of `notes.displayRef`. That advice still holds.
Tree notes do not show in `git log` anyway (fact 4).

**Records: one JSON object per line** (the owner's answer: "JSON is a-ok").

A result record:

```json
{"v":1,"id":"<uuid>","test":"t/foo.t","status":"fail",
 "config":"linux-perl5.40","host":"<runner name>",
 "env":{"os":"linux","distro":"Ubuntu 24.04","perl":"5.40.1"},
 "started":"2026-11-24T10:00:00Z","elapsed":1.92,"exit":1,
 "planned":12,"passed":11,"failed":1,"skipped":0,"todo_passed":0,
 "output":"ok 1 ...\nnot ok 2 ...","output_cut":false,
 "ci":{"run":"<CI run id or URL>"}}
```

The status is one of `pass`, `fail`, `skip` (skip all) and `bailout`. The
counts carry the detail.

A coverage record, one for each pair of test and file:

```json
{"v":1,"test":"t/foo.t","file":"lib/Foo.pm","blob":"<git blob id>",
 "lines":[3,4,5,9],"config":"linux-perl5.40"}
```

The `blob` field holds the git blob id of the file. Then a reader can match the
lines to the exact version of the file. The `id` field in a result lets
`export --append` skip records that it has seen.

The fields keep the four parts of the sketch:

| Sketch part | Field |
|---|---|
| "Name of the relevant test & whether it overall passed/failed" | `test`, `status` |
| "Hostname of runner & other environmental information" | `config`, `host`, `env` |
| "The raw test output" | `output` |
| "Coverage matrix of said test" | coverage records in the coverage ref |

**Size limits** (my addition). The output of a passing test is cut to
`tms.maxPassOutput` (default 4 KiB). The output of a failing test is kept up to
`tms.maxFailOutput` (default 1 MiB). The field `output_cut` shows a cut.

**Where the notes go** (my addition, from fact 9). Notes can go to the code's
own remote, or to a separate results repository. A notes push does not need the
trees. A separate repository keeps the code repository small, and it lets CI
write results without write access to the code.

### 4.3 The results producer

`App::Prove::Plugin::GitTMS` is an App::Prove plugin. Its `load()` reads its
arguments (`config=`, `env=`, `ref=`) and sets the harness class to
`Git::TMS::Harness` (fact 15).

`Git::TMS::Harness` is a `TAP::Harness` subclass. It does two things:

- In `made_parser`, it collects the raw TAP of each test (fact 16).
- In `after_test`, it builds the record and appends it to the note of the
  tree in the ref of the configuration.

Then:

- It works with `prove -j`, because the callbacks run in the harness process.
- It works for any test that prints TAP, through `prove --exec`. That includes
  Test2 tests run by prove.
- It works with `rprove` (fact 17). In that case, the CI job gives the
  environment with `env=` or a file, because the local host is not the host
  that ran the tests.
- `prove -m` (merge) puts standard error into the output. The docs tell CI to
  use it.

A yath plugin, `App::Yath::Plugin::GitTMS`, does the same for yath users
through `handle_event` and `finish` (fact 18). It comes after the first
version. App::Prover gets a sink later too.

### 4.4 The coverage producer

`Devel::Cover::Report::Gittms` is a Devel::Cover report module. `cover` loads
it (fact 11). `get_options` takes `-config` and `-ref` (fact 12). `report()`
then does this:

1. Get the tree, as in 4.2.
2. For each run in `$db->{runs}`, take the test from `run` (fact 13).
3. For each file of the work tree that the run counted, check that the MD5 of
   the file on disk equals the run's digest. If the digests differ, skip the
   file.
4. Turn the counts into line numbers. Compute the git blob id.
5. Append one coverage record for each pair of test and file.

Steps 3 and 4 already exist in perl-tests-covering (fact 14). Section 8 says how
to share that code.

The report needs the per-test runs. So CI must run the tests one process per
test under `-MDevel::Cover`, as `prove` does. `cover -test`, which goes through
`make test`, gives the same result.

### 4.5 The `git tms` command

The four commands of the sketch stay as the sketch names them. The sketch's
`--os` becomes `--config`, because the configuration is now the unit.

| Command | Source | What it does |
|---|---|---|
| `git tms results [--config C]... [--raw] [--coverage] <rev or range>` | sketch | For each commit, read its tree. Show one line for each test and configuration. `--raw` adds the output. |
| `git tms scan --unreliable <range>` | sketch | List tests that have both a pass and a fail for the same tree and configuration. |
| `git tms scan --where-fails <test> <rev>` | mine | List the configurations, and hosts, that fail a test at a tree. |
| `git tms record [--status S] [--covers X]... [--config C] [--at rev] <file>` | sketch | Record a manual test. It opens `$EDITOR` for the output unless `--output FILE` is given. |
| `git tms export [--append] <range> <db.sqlite3>` | sketch | Write the results of a range to SQLite with `schema/tms.sql`. |
| `git tms push [remote]` | mine | Push every local `refs/notes/tms/*` ref. On a refusal, fetch, merge with `cat_sort_uniq`, and push again, up to three times. |
| `git tms fetch [remote]` | mine | Fetch all configurations into `refs/notes/tms-remote/<remote>/`. |
| `git tms log [<git log options>]` | mine | `git log` with a column for the results of each commit's tree. It is needed because `git log --notes` cannot show tree notes (fact 4). |

**Reading many configurations.** The reader lists the refs under
`refs/notes/tms-remote/<remote>/results/` and the local `refs/notes/tms/results/`.
For a range, it runs `git log --format='%H %T'` once. Then it reads the notes
of all the trees through one `git cat-file --batch` process, not one `git` call
for each note. A reader never runs `git notes prune` (fact 10). A clone that
lacks old trees (for example a shallow CI clone) deletes good results that way.

### 4.6 Hooks

Hooks leave the main design (the owner's answer). An optional `pre-push` hook
that runs `git tms push` can come later, for developers who run the producers
on their own hosts. It is not in the first version.

### 4.7 Reporting

- **In the terminal**: `git tms results`, `git tms scan` and `git tms log`.
- **SQLite**: `git tms export` (from the sketch). The tables are in 4.8. Any
  SQLite viewer, or the SQLite data source for Grafana, can then draw charts.
  An example is "coverage as development trundles along" (from the sketch).
- **TestRail** (later): an exporter that maps a tree to a TestRail run and a
  configuration to a TestRail configuration, through TestRail-Perl.

### 4.8 SQLite schema (`schema/tms.sql`)

The sketch asks for a schema "as generic as possible to account for
multi-programming language repositories". The tables:

- `commits (sha PK, tree, committed_at, subject)`
- `configurations (name PK, os, distro, runtime, env_json)`
- `results (id PK, tree, test, status, config, host, started, elapsed, exit,
  planned, passed, failed, skipped, output)`
- `result_covers (result_id, target)` for `record --covers`. A target is a file
  or one of the "more nebulous things like concepts" (from the sketch).
- `coverage (tree, config, test, file, blob, lines)`

`results` joins to `commits` on `tree`.

## 5. First version (0.01)

Goal: a CI matrix writes results for each configuration, and anybody with a
clone can ask where a test fails. This is useful on its own. It replaces the
question "which CI job was that?" with a git command.

In it:

1. `Git::TMS::Store`: read and write the JSON-line notes on trees, one ref for
   each configuration, and fetch, merge and push.
2. `App::Prove::Plugin::GitTMS` and `Git::TMS::Harness`.
3. Environment detection (OS, distribution, perl version, host name), and
   `env=` to override it.
4. `git tms push`, `fetch`, `results` and `scan --where-fails`.
5. Fixes to the defects of `bin/git-tms` that section 2 lists.
6. Tests against throwaway repositories with a bare remote. They cover facts 6,
   7, 8 and 9 and the check of tracked files in 4.2.
7. A CI example with a matrix of two configurations, in the docs.
8. `dist.ini` and a CPAN release as `Git::TMS`.

Left out of 0.01:

- the coverage producer
- `scan --unreliable`, `record`, `export`, `log`
- the yath plugin and the App::Prover sink
- the TestRail exporter
- hooks
- a separate results repository (it works by fact 9, but the docs and the
  tests come later)
- Windows

## 6. Milestones after 0.01

In this order:

1. **`scan --unreliable` and `git tms log`.** Both need only the store and
   0.01 data. `scan --unreliable` is the first payoff of history: it finds
   flaky tests.
2. **The coverage producer.** `Devel::Cover::Report::Gittms`, with the code
   shared with perl-tests-covering (section 8). `results --coverage` reads it.
3. **`export` to SQLite and `schema/tms.sql`.** This gives charts and ad hoc
   queries over results and coverage.
4. **Test selection from CI coverage.** perl-tests-covering reads the coverage
   notes that CI pushed. A new clone can then choose tests without a full local
   run. This is the Readme's "coverage data ought to be reasonably up-to-date"
   idea.
5. **The yath plugin.**
6. **`record` for manual tests.**
7. **A separate results repository**, with docs and tests.
8. **The TestRail exporter.**
9. **The App::Prover sink.**

## 7. Risks and open questions

### Risks

- **Repository growth.** Notes are ordinary git objects, and nobody can remove
  them from clones that fetched them. A matrix of N configurations writes N
  notes for each tree that CI tests. Coverage is much larger than results. One
  ref for each kind and configuration, the size limits and a separate results
  repository all reduce this. I have no measurements yet. 0.01 prints the size
  of each ref in `git tms results --stats`.

Answer: We've had similar concerns with perl-tests-covering.  We ended up
with a number of mitigation strategies, such as gzipping the json, only running
relevant tests, etc.  For our purposes we will *only* care about the text output
of *abnormal* e.g. nonpassing assertions, which will also cut down on size.
The other data to gather of note is test runtime; when that's particular
standard deviations outside of the norm it's almost always indicative of a real
problem.

- **Code outside the tree.** A tree fixes the code, not the CPAN modules, the
  system libraries or the perl. The configuration name and the `env` field
  carry those. Two runs of one configuration with different dependencies look
  like a flaky test. See open question 2.

A flake or failure caused by an incorrect CI configuration is as worth fixing
as a customer facing bug, in fact moreso - quality is downstream of process.
This will reveal such failures.

- **`git notes prune`.** It deletes results for trees that the clone lacks
  (fact 10). The docs warn about it. `git tms` never runs it.

That's probably fine?  In practice most people don't care about trends on things
other than the primary branch/tree.

- **Forges.** I did not check how each forge treats notes refs. Test this
  before 0.01 ships.

This needs to be looked into deeper.

- **Credentials.** CI must push to a remote. Many CI systems give a read-only
  token by default.

We can circumvent this problem with custom runners hooked into CI - e.g.
run everything on our own hypervisor which can have as much access as it likes.

Alternatively, we can make a service shim listening somewhere we ship these
results to which then pushes the notes.

- **Secrets in output.** Output can contain tokens or paths. Once pushed, it is
  in every clone. I propose a filter command (`tms.outputFilter`) in 0.01, and
  a warning in the docs.

Agree

### Open questions for the owner

1. **The configuration as the unit.** I chose one ref for each configuration,
   named by the CI job, and kept the host name inside each record. Is a
   configuration the right unit, or do you want one ref for each host?

configuration is the right unit.  Specific hosts are meaningless to this problem.

2. **Dependencies.** Must a configuration record its dependency versions (for
   example a hash of the installed modules or of a `cpanfile.snapshot`)? If
   yes, is a change of dependencies a new configuration, or a field that
   `scan --unreliable` compares?

No, that's far too multivariate.  It's only useful in a narrow band of circumstances.
If a failure occurs due to insufficiently specified deps the test output will
in nearly all circumstances make that clear, and the exceptions are rare enought
to not be worth the ballooning in size/complexity this implies.

3. **Where the notes live.** In the code repository, or in a separate results
   repository? The separate repository keeps the code small and needs no write
   access to the code.

This should be *configurable*, yes.  Some very large repos or CI situations may
necessitate this, but it won't be a problem for say the average perl module on CPAN.

4. **Prove or yath in CI.** Which harness do your CI jobs use? If it is yath,
   the yath plugin moves into 0.01.

We should support both, they both have pluggable facilities which should suffice.

5. **Coverage depth.** Are statement lines enough, or do you want branches and
   conditions too? Each one adds a lot of data.

Just the statement coverage % per file will suffice yes.

6. **Manual tests.** Are they still in scope? If yes:
   - Is a manual test always a file in the repository, with its path as its
     name?

That should be the assumption to operate under, yes.

   - Is `--status` the way to give the result, as I proposed?

Sounds fine to me.

   - Is a `--covers` concept free text, or does it link to a list of concepts?

We should probably use a similar idiom as perl-tests-covering, e.g. 'here is the list of specific files pertinent'.
Manual tests should be markdown with a structured data section at the top, like skills, which describe these things.
This would be tedious for a manual tester to keep up to date & track down, but is now trivial in the age of AI agents.

7. **Retention.** Do you want a way to retire old results, for example by
   moving notes of trees older than a year to an archive ref?

sounds good to me.

8. **Windows.** Is a Windows configuration in the matrix early on?

I'm sure it will be for someone at some point, so Test::Portability concerns are gonna be a big deal yes.

## 8. The owner's related tools

| Tool | Relation to git-tms | Proposal |
|---|---|---|
| **perl-tests-covering** | It already reads Devel::Cover runs and turns them into lines and git blob ids for each test (fact 14). That is the core of the coverage producer. It also chooses tests for a change, which the Readme asks for. | Move `_files_covered`, `_record` and the code they call into a public module, for example `Perl::Tests::Covering::Runs`. The coverage producer uses it. In milestone 4, tests-covering learns to read coverage notes. Its own cache in `~/.cache` stays as the local copy. |
| **TestRail-Perl** | A client for a TMS. Its prove plugin sets a harness subclass, the same pattern as the results producer (fact 15). | Keep. Use its plugin as a model now, and its API for the exporter in milestone 8. |
| **perl-App-Prove-Remote** (`rprove`) | It runs prove on the local host and each test on a remote host over SSH (fact 17). That is one way to run a matrix of hosts from one CI job. | Keep. If the job gives the environment of the remote host, the results producer works with it. Document the combination. |
| **perl-app-prover** (App::Prover) | A test runner with pluggable sinks. Its events carry the file, each assertion, the raw output, the exit code and the time. | Milestone 9: an `App::Prover::Sink::GitTMS`. |
| **TestLink-Perl** | A client for TestLink's XML-RPC API. Last changed in 2015. | Unrelated to this plan. |
| **Git-Elasticsearch** | It indexes the git log into Elasticsearch, per file. Its README calls it an add-on to App-Prove-Elasticsearch. It has not changed since 2019. | Unrelated to this plan. git-tms needs no index of the git log, because results sit on the trees. Nothing in this plan needs it. Whether to retire it is a separate decision. |

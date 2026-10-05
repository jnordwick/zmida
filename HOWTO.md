# zmida HOWTO

Part 1 is everything you need for day-to-day use. Part 2 is the knobs
for when you care about the last few percent of noise.

# Part 1: Basics

## 1.1 Your first benchmark

``` zig
const std = @import("std");
const zm = @import("zmida");

pub fn main(init: std.process.Init) !void {
    const args = zm.gen.uniform(f64, 100, 0, 10, 0);
    try zm.bench(&init, .{ f_a, f_b }, &args);
}
```

Run it in a release mode, otherwise the numbers mean little (zmida will
warn you):

``` {.bash org-language="sh"}
zig build run -Doptimize=ReleaseFast
```

`bench`{.verbatim} is `bench_ex`{.verbatim} with the defaults. A single
function does not need a tuple:
`zm.bench(&init, f_a, &args)`{.verbatim}.

The functions must be known at compile time (a literal function or tuple
of functions, not a runtime function pointer). Names in the output come
from the function names.

## 1.2 What gets called: the argument forms

The third argument says what to call each function with. zmida figures
out the form from its type.

  you pass                                 each sweep does
  ---------------------------------------- -------------------------------------------------------
  `{}`{.verbatim}                          calls `f()`{.verbatim} once (niladic)
  `.{ a, b }`{.verbatim}                   calls `f(a, b)`{.verbatim} once (a tuple)
  `&xs`{.verbatim} or a slice of scalars   calls `f(x)`{.verbatim} for every element
  `&ts`{.verbatim} or a slice of tuples    calls `f(t[0], t[1], ...)`{.verbatim} for every tuple
  a generator (see 1.3)                    calls `f(...)`{.verbatim} for every value produced

Rules of thumb:

-   Naked values are only for arrays and slices of single arguments. A
    single argument that is not in an array goes in a tuple:
    `.{x}`{.verbatim}.
-   Arrays must be passed by pointer: `&xs`{.verbatim}, not
    `xs`{.verbatim}. Passing an array by value is a compile error that
    tells you so.
-   If a value is ever misidentified, wrapping it in a tuple forces the
    single-call form.
-   The argument list must not be empty.

The same arguments are given to every function, so functions that take
the same inputs can be compared directly.

## 1.3 Making arguments

`zm.gen`{.verbatim} has helpers. Everything is generated before timing
starts, so none of it costs anything inside a sample (except generators,
see below).

### Random arrays

``` zig
const xs = zm.gen.uniform(f32, 100, 2, 10, 0);   // type, count, from, to, seed
```

The seed is explicit so every run sees the same inputs. Integers are in
`[from, to]`{.verbatim}, floats in `[from, to)`{.verbatim}. The count is
comptime, so very large arrays live on the stack; make them
`const`{.verbatim} or `static`{.verbatim} in a bigger program.

### Multiple arguments

`tie`{.verbatim} zips arrays into an array of tuples, and broadcasts any
non-array (a scalar, a pointer, anything) to every tuple:

``` zig
const bases = zm.gen.uniform(f32, 100, 2, 10, 0);
const xs    = zm.gen.uniform(f32, 100, 10, 100, 0);
const args  = zm.gen.tie(.{ bases, xs });         // [100]struct{ f32, f32 }
try zm.bench(&init, .{ std_log, builtin_log }, &args);

const args2 = zm.gen.tie(.{ @as(f32, 2.0), xs }); // 2.0 for every call
```

Arrays in the tuple must all have the same length. `tie2`{.verbatim} and
`tie2t`{.verbatim} are the two-array special cases; `tie2t`{.verbatim}
also puts the type first, for functions like `std.math.log`{.verbatim}
that take a comptime type as their first argument.

### Generators

Instead of materializing the arguments, a generator makes them on the
fly:

``` zig
const ls = zm.gen.LinSpace(f32).init(1, 10, 100); // 100 points, both ends included
const r  = zm.gen.Range(u64).init(0, 1000, 10);   // 0, 10, ..., 1000 (inclusive)
try zm.bench(&init, just_log, ls);
```

Pass generators by value, not by pointer. `LinSpace`{.verbatim} needs at
least 2 points.

Generator code runs inside the timed loop. `Range`{.verbatim} and
`LinSpace`{.verbatim} are an add and a compare, but anything heavier
(like a random number generator) becomes part of what you measure. For
anything non-trivial, materialize an array instead.

To write your own: a struct with

-   `pub const __zm__generator__ = true;`{.verbatim} (the marker)
-   a `len: u64`{.verbatim} field, the number of values one sweep
    produces
-   `pub fn next(this: *@This()) ?struct { ... }`{.verbatim}, returning
    a tuple of arguments, or null at the end

## 1.4 Reading the output

Progress goes to stderr, results to stdout, so piping and redirecting
the results works.

``` example
study: gamma
compile: .ReleaseFast
units: nanosec/op
clock: .tsc @ 1497600000 Hz
display: latency (lower is better)

fn         |      calls  seconds    mean |   best     p75     p50     p25   worst
-----------+-----------------------------+---------------------------------------
logtgamma  |   12638100     3.04  240.37 | 238.46  239.60  240.22  240.77  264.67
```

-   **calls**, **seconds**: total calls and total timed seconds in the
    trial.
-   **mean**: total time / total calls.
-   **best .. worst**: each sample is a whole batch of calls, and these
    are per-call figures of individual samples, not individual calls. So
    \"best\" is the fastest sample, not the fastest call.
-   The percentile columns are **performance** percentiles, listed from
    best to worst: p75 means 75% of samples were slower than this. In
    latency mode that is the 25th percentile of latency. In throughput
    mode the labels read the usual way.
-   The unit scales itself (ns, us, ms, s per op; ops, Kops, Mops, Gops
    per second).

Standard deviation is deliberately not reported; latency distributions
are right-skewed, and the spread columns tell you more.

If perf counters are on (see 2.3), a second table follows. All columns
are per call:

  column     meaning
  ---------- ------------------------------------
  ipc        instructions per cycle
  insts      instructions retired
  cycles     CPU cycles
  imiss      L1 instruction cache read misses
  miss/M     branch misses per million branches
  misses     branch misses
  branches   branches

## 1.5 Throughput instead of latency

Latency is the default for `bench`{.verbatim}. To flip it, use a
`Study`{.verbatim} (next section) and
`study.write_text(null, .{ .mode = .thru })`{.verbatim}.

## 1.6 Using a Study

`bench`{.verbatim} throws the study away after printing. To keep it and
write other formats:

``` zig
pub fn main(init: std.process.Init) !void {
    zm.init(&init, .{});
    var study = try zm.Study.run("my study", .byadapt(.{}), .{ f_a, f_b }, &args);
    defer study.deinit();

    try study.write_text(null, .{});
    try study.write_summary("my", .{});     // my-summary.csv
}
```

`zm.init`{.verbatim} must be called once, before the first
`Study.run`{.verbatim} (`bench`{.verbatim} does it for you). Each
`write_*`{.verbatim} takes a file name or `null`{.verbatim} for stdout.
When a name is given, a suffix is added and the file is created (or
truncated) in the current directory:

  method                            suffix                      content
  --------------------------------- --------------------------- -----------------------------------------------
  `write_text`{.verbatim}           `.txt`{.verbatim}           the tables above
  `write_summary`{.verbatim}        `-summary.csv`{.verbatim}   one row per function: mean, percentiles, perf
  `write_samples`{.verbatim}        `-samples.csv`{.verbatim}   every sample: fn, calls, nanos
  `write_gnuplot`{.verbatim}        `.gp`{.verbatim}            self-contained gnuplot script, throughput
  `write_gnuplot_perf`{.verbatim}   `-perf.gp`{.verbatim}       gnuplot multiplot of the perf counters

In the CSV summary the percentile columns are the usual latency
percentiles (`p0`{.verbatim} is the fastest, `p100`{.verbatim} the
slowest), which is the reverse of the text table labels in latency mode.
In `-samples.csv`{.verbatim} the `time`{.verbatim} column is the total
nanoseconds for the whole sample; divide by `calls`{.verbatim} for
per-call latency.

To plot: `gnuplot -p my.gp`{.verbatim}. The perf plot needs perf
counters enabled, otherwise there is nothing to draw.

# Part 2: Advanced

## 2.1 Choosing a trial type

``` zig
.byadapt(.{})   // default
.bytime(.{})
.bycount(.{})
```

**Adaptive** (default). You say how long you want a trial to take and
how many samples; zmida runs a short timed calibration, works out how
many sweeps fit in a sample, then runs the samples by count. No timer
thread interferes during the samples. Defaults: 1s warmup, 100 samples,
2s of samples, 2s of perf counting.

**Count.** You choose the number of calls (`warmup_calls`{.verbatim},
`trial_samples`{.verbatim}, `sample_calls`{.verbatim},
`perf_calls`{.verbatim}). Calls are rounded up to whole sweeps over the
argument list. Good when you want exactly reproducible work, or when
something else decides how long a sample is.

**Timed.** Each sample runs until a helper thread says stop. Samples are
`trial_millis / trial_samples`{.verbatim} long. Use it if you really
want wall-clock-bounded samples, such as when a single sweep takes a
long time.

A trial costs about warmup + trial time (+ perf time) per function, so
the defaults are \~3s per function, \~5s with perf counters.

## 2.2 Setting options in code and on the command line

Global options live in `EnvOpts`{.verbatim}:

``` zig
zm.init(&init, .{
    .verbose = 1,      // 0 silent, 1 normal, 2 trace
    .use_tsc = true,
    .pin_cpu = 1,
    .set_prio = -5,    // negative needs root
    .perf_cpu = true,
    .perf_mem = false,
});
```

or `zm.bench_ex(&init, env_opts, config, funcs, args)`{.verbatim}.
Options only apply to the first init; later `bench_ex`{.verbatim} calls
do not change them.

Command line switches override whatever the code says, so you can leave
the code alone and run `./prog -c=3 -p=both -v=2`{.verbatim}. Switches
take the form `-x=value`{.verbatim}; `-x value`{.verbatim} does not
work. `-t`{.verbatim} alone turns TSC on, `-t=off`{.verbatim} turns it
off. The full list is in the README. zmida rejects any argument that
begins with `-`{.verbatim} and that it does not know, so don\'t reuse
those for your own program.

## 2.3 Perf counters

`-p=cpu`{.verbatim} (or `.perf_cpu = true`{.verbatim}) adds
instructions, cycles, branch and L1i counters. `-p=mem`{.verbatim} adds
the data cache and last-level cache counters. `-p=both`{.verbatim} does
both.

Things to know:

-   Counters are collected in a **separate** run after the timing
    samples, so they cannot perturb the timing.
-   Only user-space is counted, in the calling thread.
-   The cpu group is pinned to the PMU so it is exact. The mem events
    are not, so the kernel may multiplex them; zmida scales by
    enabled/running time. Treat the mem numbers as estimates.
-   Counters need `kernel.perf_event_paranoid <`{.verbatim} 2=. If you
    see an `errno_acces`{.verbatim} or `errno_perm`{.verbatim} error,
    that is usually the reason:
    `sudo sysctl kernel.perf_event_paranoid=2`{.verbatim}.
-   Errors like `errno_noent`{.verbatim}, `errno_inval`{.verbatim}, or
    `errno_opnotsupp`{.verbatim} mean the CPU or hypervisor does not
    provide that event. Cache events especially are patchy on VMs and
    hybrid CPUs.

## 2.4 A quiet machine

For stable numbers:

-   Pin with `-c=N`{.verbatim}, preferably to a core that has been
    isolated from the scheduler (`isolcpus`{.verbatim},
    `nohz_full`{.verbatim}) and not a hyperthread sibling of a busy
    core.
-   With pinning on, zmida reads the cpufreq settings of that core and
    warns when the governor is not `performance`{.verbatim} (or, for
    `intel_pstate`{.verbatim} / `amd-pstate-epp`{.verbatim}, when the
    energy-performance preference leans to power saving). It only warns.
    `-v=2`{.verbatim} prints what it found.
-   The helper thread used by the timed trial type and the warmup is
    kept off the pinned core.
-   `-n`{.verbatim}-10= raises priority (needs root).
-   Close the browser.

## 2.5 The clock

By default zmida uses the TSC, read with `lfence=/=rdtsc`{.verbatim}
before and `rdtscp=/=lfence`{.verbatim} after, which is much cheaper
than a syscall. It requires an invariant TSC, and it learns the
frequency from CPUID leaf 0x15, then 0x16. If that is not possible (AMD,
many VMs), it prints a warning and uses
`clock_gettime(CLOCK_MONOTONIC_RAW)`{.verbatim}, which is a perfectly
good clock when samples are reasonably long (they are, by default).

The frequency from CPUID is nominal. To cross-check, run the same thing
with `-t=off`{.verbatim} and compare the numbers; they should agree to
within a percent or so. The header line `clock: .tsc @ N Hz`{.verbatim}
tells you which one was used.

## 2.6 Keeping the compiler honest

The harness uses `doNotOptimizeAway`{.verbatim} on the arguments and on
the result of every call, but the compiler can still do clever things
when it can see everything. Two controls:

**Inside your function.** If the compiler can prove an input is
constant, it may fold the work away. Take inputs from the argument list,
not from literals in the function.

**The call modifier.** By default calls use `.auto`{.verbatim}. To
change how the harness invokes your functions, declare this in the
**root source file of your executable** (the file with
`main`{.verbatim}, not a helper file):

``` zig
pub const __zm__callmod__ = std.builtin.CallModifier.always_inline;
```

`always_inline`{.verbatim} lets the function body be optimized together
with the loop; `never_inline`{.verbatim} keeps it a real call. When set,
zmida says so at startup with verbosity 1.
`example/plots.zig`{.verbatim} uses this, and compares a direct call, a
function-pointer call and a method call.

## 2.7 Baseline overhead

The loop, the `doNotOptimizeAway`{.verbatim} calls, and the timer
start/stop are in every measurement, and there is no automatic
subtraction. Measure it yourself by benchmarking a function that does
nothing:

``` zig
fn nothing(x: u64) u64 {
    std.mem.doNotOptimizeAway(&x);
    return x;
}
```

and put it in the tuple next to the functions you care about.
`example/plots.zig`{.verbatim} does this (`ccall`{.verbatim}) and the
difference between it and the others is the part that is yours.

## 2.8 Reading results in code

Everything the writers use is public:

``` zig
try study.statistics();    // safe to call more than once
for (study.stats.items) |s| {
    std.debug.print("{s}: {d:.2} ns/call, p50 {d:.2}\n", .{
        s.trial.name, s.call_avg_ns, s.percentiles[50],
    });
}
for (study.trials.items[0].data.items) |sample| {
    // sample.ord, sample.calls, sample.nanos
}
```

Note `percentiles`{.verbatim} is indexed best-first: `[0]`{.verbatim} is
the worst latency, `[100]`{.verbatim} the best. Don\'t add trials to
`study.trials`{.verbatim} after calling `statistics()`{.verbatim}; the
stats hold pointers into it.

## 2.9 Troubleshooting

  symptom                                                        what to check
  -------------------------------------------------------------- -------------------------------------------------------------------
  `!!! WARNING !!! Compiled in debug mode`{.verbatim}            build with `-Doptimize=ReleaseFast`{.verbatim}
  `!!! WARNING !!! No capable TSC. using monotonic`{.verbatim}   no invariant TSC / CPUID leaves; harmless
  `unknown option name: ...`{.verbatim}                          an argument starting with `-`{.verbatim} that isn\'t zmida\'s
  `pin cpu wants cpu number`{.verbatim}                          wrote `-c 1`{.verbatim}; use `-c=1`{.verbatim}
  perf `errno_acces`{.verbatim} / `errno_perm`{.verbatim}        `perf_event_paranoid`{.verbatim}
  `could not set cpu affinity`{.verbatim}                        that cpu is not in your allowed set
  a function that takes 0.3 ns                                   the compiler removed it; see 2.6 and 2.7
  worst case 3-8x the median                                     normal: interrupts, SMIs, migrations. Pin, isolate, look at p50
  first function in a study looks slower                         cold shared tables; put a throwaway copy first, or rely on warmup

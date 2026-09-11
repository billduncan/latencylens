# latencylens

Side-by-side kernel density comparison of two latency samples, faceted by
whatever dimension you care about -- customer, brand, service, route,
region, canary vs. control, before vs. after a release.

Background: [(Ab)use of the R Language](https://billduncan.org/abuse-of-the-r-language/)
and its follow-up on billduncan.org.

## Why

A single average, or even a p95, collapses a whole distribution into one
number. Two periods can have nearly identical averages and completely
different shapes -- a short blip of very slow requests, a second mode
that appears out of nowhere, a long tail that got longer. Kernel density
plots make the shape visible; overlaying two periods on log-scaled axes
makes the *change* in shape visible.

This tool takes a plain data file and turns it into one figure: one panel
per facet value, both periods overlaid and filled, log-x/sqrt-y so both
the bulk of the distribution and its tail are readable at once, and a
small stats block (p50/p90/p95/max/avg/N/SLO%) in the corner of each
panel so you don't have to eyeball percentiles off a curve.

## Requirements

- `Rscript` (R). One-time package install:
  ```
  Rscript -e 'install.packages(c("ggplot2","dplyr","tidyr","scales"), repos="https://cloud.r-project.org")'
  ```
- bash (for the wrapper -- optional, you can call `latencylens.r` directly)

## Usage

```
latencylens [-t title] [-w warn_ms] [-s slo_ms] [-c ncol] infile output-prefix
```

`infile` is whitespace-delimited with a header line and exactly three
columns:

```
time value latency
```

- `time` -- label for which of the two periods this row belongs to.
  Must have exactly two distinct values in the file (e.g. two dates,
  two hours, `before`/`after`, `control`/`canary`).
- `value` -- the facet key. One panel per distinct value. This can be a
  customer/brand id (support-facing: "what is this customer seeing?"),
  a service or route name (engineering-facing: "which endpoints
  regressed?"), or anything else you want to slice by.
- `latency` -- latency in milliseconds.

The header line is expected but not required: if the first line isn't
exactly `time value latency`, the file is treated as headerless, the
three columns are named explicitly, and the data is revalidated (3
columns, numeric latency) so a genuine format problem still fails with a
clear message instead of a confusing "expected exactly 2 distinct time
values" one.

Output is `output-prefix.png` and `output-prefix.pdf`.

### Panel count and layout

One panel per distinct `value` -- could be 1, could be 20. Panel size
stays constant regardless: the image grows by rows/columns instead of a
fixed page size stretching a couple of panels to fill it or cramming
twenty into too little space. Columns default to `min(2, number of
values)`; override with `-c` (clamped to the number of values -- asking
for more columns than panels doesn't do anything useful). A single value
renders as a single panel, no empty facet grid cells.

Defaults can be tuned via environment variables if you want bigger or
smaller panels: `LL_PANEL_WIDTH_IN`, `LL_PANEL_HEIGHT_IN`,
`LL_MARGIN_WIDTH_IN`, `LL_MARGIN_HEIGHT_IN`, `LL_LEGEND_WIDTH_IN`. See
the header of `latencylens.r` for defaults.

### Example

```
./latencylens -t "checkout, this week vs last" checkout.dat checkout-wk
```

`example.png` in this repo (real traffic, customer IDs replaced by
obfuscated labels, a pre-incident baseline vs. an incident in progress)
was generated this way -- see the linked blog post for the story behind
that comparison.

## How it works

`latencylens` (bash) is a thin argument-validating wrapper; all the work
is in `latencylens.r`:

1. Compute p50/p90/p95/max/avg/N, and the fraction under your SLO
   threshold, per (facet, period).
2. Pivot so both periods sit side by side, and build one annotation
   string per facet.
3. Jitter latencies under 10ms into `[0,1)` before log-transforming --
   whole-millisecond values otherwise stack into comb-like spikes on a
   log axis that read as noise rather than shape.
4. `geom_density(alpha=0.4)` per period, filled and overlaid, faceted by
   `value`, log-x with explicit breaks from 1ms to 5 minutes, sqrt-y so
   a tall sharp peak doesn't flatten the rest of the panel.
5. Reference lines (green = warn threshold, red = SLO threshold) and the
   stats block anchored to each panel's top-right corner
   (`x=Inf, y=Inf`, `hjust`/`vjust` just inside 1) so it sits clear of
   the tail, which always runs along the bottom.

## What's not here

The production version of this tool also handles pulling latency data
out of load-balancer logs via BigQuery, caching exports in a GCS bucket
and locally, and grouping routes/customers via a YAML config -- all of
that is specific to the environment it was built for and isn't included.
The R script and wrapper here are the reusable part: give them a
three-column file in the format above and they don't care where it came
from.

A Julia port (CairoMakie + KernelDensity) producing the same plot exists
too; more on that in a future post.

## License

MIT. See `LICENSE`.

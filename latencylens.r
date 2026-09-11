#!/usr/bin/env Rscript
#
# @(#) latencylens.r - side-by-side kernel density comparison of two latency samples
# @(#) $Id: latencylens.r,v 1.8 2026/09/11 14:16:56 billduncan Exp billduncan $
#
# https://github.com/billduncan/latencylens
# Author: Bill Duncan (https://billduncan.org/)
# License: MIT
#
# Reads a whitespace-delimited file with three columns:
#
#   time value latency
#
#   time     - a label identifying which of the two periods being compared
#              this row belongs to (e.g. "2026-08-01", "before", "canary").
#              Must contain exactly two distinct values in the file.
#   value    - the facet key: whatever you want one panel per (customer,
#              brand, service, route, region, ... ). Rows sharing a value
#              land in the same panel.
#   latency  - latency in milliseconds, microseconds or even seconds with fractions.
#              numeric only, and keep the units the same throughout.
#
# The header line is expected but not required: if the first line isn't
# exactly "time value latency", the file is treated as headerless and the
# three columns are named explicitly, then revalidated.
#
# Usage:
#   Rscript latencylens.r infile pngfile pdffile title [warn_ms] [slo_ms] [ncol] [adjust]
#
#   infile   - input data file (see format above)
#   pngfile  - output PNG path
#   pdffile  - output PDF path
#   title    - plot title (the two period labels are appended automatically)
#   warn_ms  - optional, dashed green reference line (default 250)
#   slo_ms   - optional, dashed red reference line (default 1000)
#   ncol     - optional, panel columns (default: min(2, number of values)).
#              Clamped to the number of distinct 'value's -- no point asking
#              for more columns than panels. 1 value -> 1 panel, no facet
#              grid weirdness. Pass an empty string to skip this and still
#              set adjust below.
#   adjust   - optional, kernel density bandwidth multiplier (default 1).
#              Lower means less smoothing: real structure (separate modes
#              a fast path and a slow path, say) that a wider bandwidth
#              blurs into one shoulder can show up as distinct peaks at
#              adjust=0.5 or lower. Higher means more smoothing, useful
#              for a noisy/low-N sample where extra peaks are more likely
#              artifacts of a small sample than real structure.
#
# Panel size is held constant regardless of how many panels there are: the
# output image grows by rows/columns rather than a fixed page size getting
# stretched or squashed to fit whatever count of panels happens to show up.
# The legend gets a fixed width allowance regardless of column count, and
# the title is word-wrapped to whatever width results -- otherwise a narrow
# (e.g. single-column) layout leaves too little room and the title clips.
# Override via env vars if the defaults don't suit:
#   LL_PANEL_WIDTH_IN, LL_PANEL_HEIGHT_IN   (per-panel size, default 4 x 2)
#   LL_MARGIN_WIDTH_IN, LL_MARGIN_HEIGHT_IN (space for axis labels/title,
#                                            default 0.5 x 0.8)
#   LL_LEGEND_WIDTH_IN                      (space for the time legend,
#                                            default 1.4)
#   LL_UNIT                                 (latency unit: ms/s/us, default
#                                            ms -- picks the x-axis break
#                                            set and axis label; see the
#                                            BREAKS_* constants below)
#   LL_JITTER                               (sub-threshold jitter cutoff,
#                                            default 10 -- see section 5.
#                                            below; compared against the
#                                            raw latency value regardless
#                                            of unit)
#
suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(scales)
})

# x-axis break presets, by latency unit. Pick round, human-legible values
# rather than pure log spacing -- a log axis reads faster when the labeled
# ticks are numbers people already think in (25ms, 30s, 2min) instead of
# arbitrary powers of ten. Milliseconds is the default and by far the most
# common case (network/service latency); switch units with LL_UNIT if your
# data is in seconds or microseconds instead.
#
# milliseconds: 1ms up to 5 minutes.
BREAKS_MS <- c(1, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000,
               30000, 60000, 120000, 300000)
#
# seconds: 1s up to 1 hour, doubling past a minute rather than continuing
# to jump by round powers of ten -- this is the break set from the
# original 2018 slo-ng script latencylens grew out of. SLA thresholds
# tend to land on round seconds/minutes ("under 20s", "under 5 minutes"),
# not round powers of ten.
BREAKS_S <- c(1, 2, 5, 10, 20, 30, 60, 120, 240, 480, 960, 1800, 3600)
#
# microseconds: the millisecond set's shape, one order of magnitude
# further down -- a reasonable starting point for syscall/in-process
# timings, but the most likely of the three to need hand-tuning for your
# own data's actual range.
BREAKS_US <- BREAKS_MS * 1000

LL_UNIT <- tolower(Sys.getenv("LL_UNIT", "ms"))
if (!(LL_UNIT %in% c("ms", "s", "us"))) {
  cat(sprintf("warning: unknown LL_UNIT '%s' (want ms, s, or us); defaulting to ms\n", LL_UNIT),
      file = stderr())
  LL_UNIT <- "ms"
}
BREAKS <- switch(LL_UNIT, ms = BREAKS_MS, s = BREAKS_S, us = BREAKS_US)

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 4) {
  cat(
    "usage: Rscript latencylens.r infile pngfile pdffile title [warn_ms] [slo_ms] [ncol] [adjust]\n",
    file = stderr()
  )
  quit(status = 1)
}

infile   <- args[1]
pngfile  <- args[2]
pdffile  <- args[3]
title    <- args[4]
warn_ms  <- ifelse(length(args) >= 5, as.numeric(args[5]), 250)
slo_ms   <- ifelse(length(args) >= 6, as.numeric(args[6]), 1000)
# ncol and adjust share the same "optional trailing positional" slot problem
# -- adjust can't be passed without ncol occupying position 7 first, so an
# empty string in that slot means "use the ncol default" rather than being
# absent entirely.
ncol_arg <- if (length(args) >= 7 && nzchar(args[7])) as.integer(args[7]) else NA
adjust   <- if (length(args) >= 8 && nzchar(args[8])) as.numeric(args[8]) else 1

cat(paste("infile: ", infile),  "\n")
cat(paste("pngfile:", pngfile), "\n")
cat(paste("pdffile:", pdffile), "\n")
cat(paste("title:  ", title),   "\n")
cat(paste("warn_ms:", warn_ms, " slo_ms:", slo_ms, " adjust:", adjust, " unit:", LL_UNIT), "\n")

# 1. Load data
# Expect a "time value latency" header, but don't require it: a
# whitespace file missing its header line otherwise fails downstream with
# a confusing "expected exactly 2 distinct time values" error (the first
# data row got consumed as column names). Detect that case, re-read
# headerless with the columns named explicitly, and revalidate.
first_line    <- readLines(infile, n = 1)
header_tokens <- tolower(strsplit(trimws(first_line), "\\s+")[[1]])
has_header    <- identical(header_tokens, c("time", "value", "latency"))

if (has_header) {
  df <- read.table(infile, header = TRUE, stringsAsFactors = TRUE)
} else {
  cat("warning: no 'time value latency' header found; treating all rows as data\n",
      file = stderr())
  df <- read.table(infile, header = FALSE, stringsAsFactors = TRUE)
  if (ncol(df) != 3) {
    cat(sprintf("error: expected 3 columns (time value latency), found %d\n", ncol(df)),
        file = stderr())
    quit(status = 1)
  }
  names(df) <- c("time", "value", "latency")
}

# Revalidate regardless of which path loaded the data: a real mismatched
# header (typo'd column names, wrong delimiter, etc.) lands here too.
df$latency <- suppressWarnings(as.numeric(as.character(df$latency)))
if (any(is.na(df$latency))) {
  cat("error: 'latency' column contains non-numeric values -- check the file has exactly 3 whitespace-separated columns (time value latency)\n",
      file = stderr())
  quit(status = 1)
}

# Latency values below 1 (typically exact 0s from a source that
# truncates sub-unit timings) break the log-x axis -- log10(0) is
# -Inf, so those rows silently vanish from the density curve instead of
# showing up at the left edge. Clamp up to 1 so they land in the same
# sub-JITTER_THRESHOLD dithering as any other very-fast request below,
# rather than being dropped or left to distort the axis range.
#
# This clamp is hardcoded to 1 regardless of LL_UNIT. That's a negligible
# nudge for milliseconds, but if you're using LL_UNIT=s with genuine
# fractional-second latencies (0.3s, 0.8s, ...), it clamps all of those up
# to a full second -- a real distortion, not a rounding error. If that's
# your data, you probably want this clamp disabled (or its threshold
# lowered well below your smallest real value) rather than applied as-is.
n_clamped <- sum(df$latency < 1)
if (n_clamped > 0) {
  cat(sprintf("note: %d row(s) had latency < 1ms (including exact 0); clamped to 1ms\n", n_clamped),
      file = stderr())
  df$latency[df$latency < 1] <- 1
}

times <- unique(df$time)
if (length(times) != 2) {
  cat(
    sprintf("error: expected exactly 2 distinct 'time' values, found %d: %s\n",
            length(times), paste(times, collapse = ", ")),
    file = stderr()
  )
  quit(status = 1)
}
t1 <- times[1]
t2 <- times[2]

# Panel grid: how many values (panels) do we actually have, how many
# columns, and how big should the output be so each panel stays roughly
# the same physical size whether there's 1 panel or 20.
nvals <- length(unique(df$value))
if (!is.na(ncol_arg)) {
  ncol_use <- max(1, min(ncol_arg, nvals))
} else {
  ncol_use <- min(2, nvals)
}
nrow_use <- ceiling(nvals / ncol_use)

PANEL_W   <- as.numeric(Sys.getenv("LL_PANEL_WIDTH_IN",   "4"))
PANEL_H   <- as.numeric(Sys.getenv("LL_PANEL_HEIGHT_IN",  "2"))
MARGIN_W  <- as.numeric(Sys.getenv("LL_MARGIN_WIDTH_IN",  "0.5"))
MARGIN_H  <- as.numeric(Sys.getenv("LL_MARGIN_HEIGHT_IN", "0.8"))
LEGEND_W  <- as.numeric(Sys.getenv("LL_LEGEND_WIDTH_IN",  "1.4"))
MIN_W     <- 5
MIN_H     <- 3.5

plot_width  <- max(MIN_W, ncol_use * PANEL_W + MARGIN_W + LEGEND_W)
plot_height <- max(MIN_H, nrow_use * PANEL_H + MARGIN_H)

# Word-wrap the title to whatever width we ended up with, so a long title
# on a narrow (few-column) layout wraps to multiple lines instead of
# running off the right edge of the image. ~10 chars/inch is a rough fit
# for the default title font size; good enough to avoid clipping.
full_title    <- paste(title, "-", t1, "and", t2)
chars_per_line <- max(20, floor(plot_width * 10))
title_lines   <- strwrap(full_title, width = chars_per_line)
wrapped_title <- paste(title_lines, collapse = "\n")
plot_height   <- plot_height + 0.25 * (length(title_lines) - 1)

cat(paste("panels: ", nvals, " ncol:", ncol_use, " nrow:", nrow_use,
          " size:", plot_width, "x", plot_height, "in"), "\n")

# 2. Per-panel, per-period statistics (one pass)
stats <- df %>%
  group_by(value, time) %>%
  summarise(
    P50 = quantile(latency, 0.5),
    P90 = quantile(latency, 0.9),
    P95 = quantile(latency, 0.95),
    Max = max(latency),
    Avg = mean(latency),
    Num = n(),
    Slo = mean(latency < slo_ms),
    .groups = "drop"
  )

# 3. Pivot so both periods sit side by side for every metric
stats_wide <- stats %>%
  pivot_wider(
    names_from = time,
    values_from = c(P50, P90, P95, Max, Avg, Num, Slo)
  )

# 4. Build one annotation label per panel: "period1 / period2" for each stat
stats_wide <- stats_wide %>%
  mutate(
    label = sprintf(
      "50%%: %.1f / %.1f\n90%%: %.1f / %.1f\n95%%: %.1f / %.1f\nMax: %.1f / %.1f\nAvg: %.1f / %.1f\nN: %d / %d\nSLO: %.1f%% / %.1f%%",
      get(paste0("P50_", t1)), get(paste0("P50_", t2)),
      get(paste0("P90_", t1)), get(paste0("P90_", t2)),
      get(paste0("P95_", t1)), get(paste0("P95_", t2)),
      get(paste0("Max_", t1)), get(paste0("Max_", t2)),
      get(paste0("Avg_", t1)), get(paste0("Avg_", t2)),
      get(paste0("Num_", t1)), get(paste0("Num_", t2)),
      get(paste0("Slo_", t1)) * 100, get(paste0("Slo_", t2)) * 100
    )
  )

# 5. Plot
# Jitter sub-threshold integer latencies before taking the log: whole-
# unit values (0, 1, 2, ... -- whatever unit the data is in) stack into
# comb-like spikes once the x-axis goes log scale, which reads as noise
# rather than shape. Nudging them into [0,1) smooths the density without
# moving the real mass. The threshold (default 10) is compared against
# the raw latency value regardless of unit -- "below 10" means 10 of
# whatever unit your data happens to be in.
JITTER_THRESHOLD <- as.numeric(Sys.getenv("LL_JITTER", "10"))
set.seed(42)
df$latency_plot <- ifelse(
  df$latency < JITTER_THRESHOLD,
  df$latency + runif(nrow(df), 0, 1),
  df$latency
)

p <- ggplot(df, aes(x = latency_plot, fill = time, colour = time, y = after_stat(density))) +
  scale_x_log10(
    breaks = BREAKS,
    labels = comma_format(accuracy = 1)
  ) +
  geom_density(alpha = 0.4, adjust = adjust) +
  scale_y_sqrt() +
  geom_vline(xintercept = warn_ms, linetype = "dashed", colour = "green") +
  geom_vline(xintercept = slo_ms,  linetype = "dashed", colour = "red") +
  facet_wrap(~ value, ncol = ncol_use, scales = "free_y") +
  ggtitle(wrapped_title) +
  xlab(paste0("latency (", LL_UNIT, ")")) +
  ylab("density") +
  theme_bw() +
  theme(
    axis.text.x = element_text(angle = 30, hjust = 1, size = 6),
    # Panel-title size. Was shrunk to 5 to fit long hashed-route names;
    # short facet values (customer IDs, short route names) can use a more
    # readable default-ish size instead.
    strip.text  = element_text(size = 9)
  ) +
  # Annotation block anchored to the top-right corner of each panel (x=Inf,
  # y=Inf with hjust/vjust just inside 1) so it sits clear of the long tail,
  # which always runs left-to-right along the bottom.
  geom_text(
    data = stats_wide,
    aes(x = Inf, y = Inf, label = label),
    inherit.aes = FALSE,
    hjust = 1.05,
    vjust = 1.1,
    size = 2.3,
    lineheight = 0.9,
    alpha = 0.8
  )

# 6. Save
ggsave(pngfile, plot = p, width = plot_width, height = plot_height)
ggsave(pdffile, plot = p, width = plot_width, height = plot_height, units = "in")

cat(paste("wrote", pngfile, "and", pdffile), "\n")

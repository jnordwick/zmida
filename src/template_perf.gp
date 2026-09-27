# name inst_per_call cycle_per_call brmiss_per_call branch_per_call l1i_miss_per_call
set multiplot layout 2,3 title "{[title]s} — perf counters (per call)"
set style data histograms
set style histogram clustered gap 1
set style fill solid 0.7 border -1
set boxwidth 0.8
set xtics rotate by -45 scale 0
set grid y
unset key

set title "instructions/call"
plot $Data using 2:xtic(1) linecolor rgb "#1f77b4"

set title "cycles/call"
plot $Data using 3:xtic(1) linecolor rgb "#ff7f0e"

set title "branches/call"
plot $Data using 5:xtic(1) linecolor rgb "#2ca02c"

set title "branch misses/call"
plot $Data using 4:xtic(1) linecolor rgb "#d62728"

set title "L1i misses/call"
plot $Data using 6:xtic(1) linecolor rgb "#9467bd"

unset multiplot

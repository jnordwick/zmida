# name mean p10 p25 p50 p75 p90

set terminal pngcairo size {[width]d},{[height]d} enhanced font "Sans,12"
set output "{[ofile]s}-bars.png"

set title "{[title]s}"
set ylabel "{[units]s}"
set grid y

set style fill solid 0.65 border linecolor rgb "#40404F"
set boxwidth 0.6
set autoscale xfix
set offsets 0.5, 0.5, 0, 0
set xtics rotate by -30 scale 0 noenhanced

plot $Data using 7 with boxes title "p90" fillcolor rgb "#678DC6", \
     $Data using 3:xticlabels(1) with boxes title "p10" fillcolor rgb "#5D8AA8"

unset output

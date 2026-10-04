# name mean p10 p25 p50 p75 p90

set title "{[title]s}"
set ylabel "{[units]s}"
set grid y

set style fill solid 0.65 border
set boxwidth 0.6
set autoscale xfix
set offsets 0.5, 0.5, 0, 0
set xtics rotate by -30 scale 0

plot $Data using 0:4:3:7:6:xticlabels(1) with candlesticks \
        linecolor rgb "black" fillcolor "#7788aa" title "p10/25/75/90", \
    $Data using 0:5:(0.30) with xerrorbars linecolor "black" pointtype 0 title "median", \
    $Data using 0:2 with points pointtype 2 pointsize 1.3 linecolor rgb "#cc7033" title "mean"
 

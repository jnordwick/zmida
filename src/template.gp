# name mean p0 p10 p25 p50 p75 p90 p100

set title "{[title]s}"
set ylabel "{[units]s}"
set grid y

set style fill solid 0.5 border
set boxwidth 0.6
set autoscale xfix
set offsets 0.5, 0.5, 0, 0
set xtics rotate by -45 scale 0

plot $Data using \
        0:7:4:8:5:xticlabels(1) \
        with candlesticks \
        linecolor rgb "#1d3557" \
        fill solid 0.4 \
        title "p25/p75", \
    $Data using 0:4:(0.12) \
        with xerrorbars pointtype 0 \
        linecolor rgb "#1d3557" \
        title "p10/p90", \
    $Data using 0:8:(0.12) \
        with xerrorbars pointtype 0 \
        linecolor rgb "#1d3557" \
        notitle, \
     $Data using \
        0:6:(0.3) \
        with xerrorbars \
        pointtype 0 \
        linecolor rgb "#1d3557" \
        title "p50", \
     $Data using \
        0:3 \
        with points \
        pointtype 11 pointsize 1.0 \
        linecolor rgb "#457b9d" \
        title "min", \
     $Data using \
        0:9 \
        with points \
        pointtype 9 pointsize 1.0 \
        linecolor rgb "#457b9d" \
        title "max", \
     $Data using \
        0:2 \
        with points \
        pointtype 13 pointsize 1.2 \
        linecolor rgb "#e63946" \
        title "mean"
